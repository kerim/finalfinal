//
//  LifecycleEntrySequenceTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C3b (slice-3a-1b-everyday.md sections 2.1, 4.2 and 8): `LifecycleEntry.run`
//  now runs the save sequence (`EditorViewState.runLifecycleFlush`) BEFORE `perform`.
//
//    - the sequence runs first, with the host and controller captured at arm; `perform` runs while the writer
//      barrier is held; the tail follows; everything is released after
//    - a cancelled sequence (a section operation that never clears) means `perform` is NOT called, `run` returns
//      `.cancelled`, the cancel notice is shown, the sync services are live again and nothing is left held. The
//      abort routine's own behaviour (restart polling, re-push ids, re-post deferred rebuilds) is pinned in
//      `LifecycleAbortTests` / `LifecycleAbortRestoreTests` (round C5a)
//    - writer nil (a launch straight into Markdown, #2): the barrier is skipped and `perform` still runs
//    - a throwing `perform` leaves no barrier and no suspended service (through the abort routine)
//
//  Item 32: every test positively asserts the guard path ran (the `.armed` event, or the token seen inside
//  `perform`), so a pass-through can never make one pass vacuously.
//

import Foundation
import Testing
@testable import final_final

// File-level helpers keep the suite one level inside `LifecycleEntryStatic`, the shared serialization parent.
private struct Boom: Error, Equatable {}

private struct InsidePerform {
    var token: LifecycleToken?
    var texts: [String] = []
    var barrierRecorded = false
    var writerBarrier: UInt64?
}

extension LifecycleEntryStatic {
    @Suite("LifecycleEntry runs the save sequence — Tier 2 (t-94369a83 3a-1b C3b)", .serialized, .timeLimit(.minutes(1)))
    @MainActor
    struct LifecycleEntrySequenceTests {

        private static let fresh = "# Alpha\n\nfresh Y paragraph.\n\n# Beta\n\nfour five six.\n"

        private func prime(_ rig: LifecycleFlushHarness) {
            rig.js.answer("flushPendingBlockChanges", true)
            rig.fetchAnswer = Self.fresh
        }

        // MARK: - Order

        @Test("""
            the sequence runs BEFORE perform: F and the fresh save are in the database, the barrier is held during \
            perform, then the tail, then everything is released
            """)
        func theSequenceRunsBeforePerform() async throws {
            let rig = try LifecycleFlushHarness()
            prime(rig)
            var inside = InsidePerform()

            try await rig.withEntry {
                let outcome = try await LifecycleEntry.run(kind: .close) {
                    rig.note("perform")
                    inside.token = rig.editorState.activeLifecycle
                    inside.texts = (try? rig.paragraphTexts()) ?? []
                    inside.barrierRecorded = rig.editorState.lifecycleBarrier != nil
                    inside.writerBarrier = rig.sync.testWriterHandle?.testOpenBarrierSeq
                    return .close
                }
                #expect(outcome == .performed)
                // The slot is free again as soon as `run` returns (read here: the harness resets it on the way out).
                #expect(LifecycleEntry.current == nil)
            }

            // Positive proof the guard path ran (item 32).
            #expect(inside.token?.kind == .close)
            #expect(rig.entryEvents.first == .armed(.close))
            #expect(inside.texts.contains("fresh Y paragraph."), "FB must have landed before perform ran; got \(inside.texts)")
            #expect(inside.barrierRecorded, "the barrier is held while perform runs (N9: recorded in lifecycleBarrier)")
            #expect(inside.writerBarrier != nil, "and open on the writer")
            let poll = try #require(rig.log.firstIndex(of: "poll"))
            let fetch = try #require(rig.log.firstIndex(of: "fetch"))
            let perform = try #require(rig.log.firstIndex(of: "perform"))
            let tail = try #require(rig.log.firstIndex(of: "tail:close"))
            #expect(poll < fetch && fetch < perform && perform < tail, "log: \(rig.log)")
            // Released after every outcome (N9) and the token cleared.
            #expect(rig.editorState.lifecycleBarrier == nil)
            #expect(rig.sync.testWriterHandle?.testOpenBarrierSeq == nil, "no barrier may be left open after the run")
            #expect(rig.editorState.activeLifecycle == nil)
        }

        // MARK: - Cancelled

        @Test("""
            a section operation that never clears CANCELS a close: perform is NOT called, run returns .cancelled, the \
            close notice is shown, no tail runs, nothing is left held, and the sync services are live again
            """)
        func cancelledClose_doesNotPerform() async throws {
            let rig = try LifecycleFlushHarness()
            prime(rig)
            let toasts = ToastCenter()
            rig.editorState.toastCenter = toasts
            let footnotes = rig.attachFootnoteService()
            rig.controller.testSetIsPerforming(true)
            defer { rig.controller.testSetIsPerforming(false) }
            var performed = 0
            var outcome: LifecycleRunOutcome?

            try await rig.withEntry(bounds: LifecycleBounds.production.scaled(0.2)) {
                outcome = try await LifecycleEntry.run(kind: .close) {
                    performed += 1
                    return .close
                }
                // The slot is free again as soon as `run` returns (read here: the harness resets it on the way out).
                #expect(LifecycleEntry.current == nil)
            }

            #expect(rig.entryEvents.first == .armed(.close), "the guard path ran")
            #expect(outcome == .cancelled)
            #expect(performed == 0, "perform must never be called for a cancelled lifecycle")
            #expect(toasts.current?.message == ToastFactory.lifecycleCloseCancelled().message)
            #expect(toasts.current?.style == .warning)
            #expect(!rig.log.contains { $0.hasPrefix("tail:") }, "no tail may run; log: \(rig.log)")
            #expect(rig.editorState.activeLifecycle == nil)
            #expect(rig.editorState.lifecycleBarrier == nil)
            #expect(rig.editorState.lifecycleFlushDoneFor == nil)
            footnotes.checkAndUpdateFootnotes(footnoteRefs: ["1"], projectId: rig.pid, fullContent: "x[^1]")
            #expect(footnotes.testHasPendingUpdate, "the service was suspended at arm and must be live again after the cancel")
            footnotes.reset()
        }

        @Test("a cancelled project SWITCH shows the other cancel notice (any open or switch, B17)")
        func cancelledSwitch_showsTheOtherNotice() async throws {
            let rig = try LifecycleFlushHarness()
            prime(rig)
            let toasts = ToastCenter()
            rig.editorState.toastCenter = toasts
            rig.controller.testSetIsPerforming(true)
            defer { rig.controller.testSetIsPerforming(false) }
            var performed = 0

            try await rig.withEntry(bounds: LifecycleBounds.production.scaled(0.2)) {
                let outcome = try await LifecycleEntry.run(kind: .projectSwitch) {
                    performed += 1
                    return .open
                }
                #expect(outcome == .cancelled)
            }

            #expect(rig.entryEvents.first == .armed(.projectSwitch))
            #expect(performed == 0)
            #expect(toasts.current?.message == ToastFactory.lifecycleCancelled().message)
        }

        // MARK: - Writer nil (#2)

        @Test("writer nil (a launch straight into Markdown, #2): the barrier is skipped, FB is written directly, perform is called")
        func writerNil_isFlushed_andPerformRuns() async throws {
            let rig = try LifecycleFlushHarness()
            prime(rig)
            // A block-sync service that was never configured: it has no writer.
            let noWriter = BlockSyncService()
            noWriter.testJSEvaluator = rig.sync.testJSEvaluator
            rig.editorState.blockSyncService = noWriter
            #expect(noWriter.testWriterHandle == nil, "precondition: no writer")
            var performed = 0

            try await rig.withEntry {
                let outcome = try await LifecycleEntry.run(kind: .close) {
                    performed += 1
                    return .close
                }
                #expect(outcome == .performed)
            }

            #expect(rig.entryEvents.first == .armed(.close), "the guard path ran")
            #expect(performed == 1, "no writer must NOT abort the close (#2)")
            #expect(rig.log.contains("tail:close"))
            #expect(try rig.paragraphTexts().contains("fresh Y paragraph."), "FB was written directly")
            #expect(rig.editorState.lifecycleBarrier == nil, "there was nothing to hold")
            withExtendedLifetime(noWriter) {}
        }

        // MARK: - perform throws

        @Test("a throwing perform is rethrown and leaves no barrier open, no token, and no suspended service")
        func throwingPerform_releasesEverything() async throws {
            let rig = try LifecycleFlushHarness()
            prime(rig)
            let footnotes = rig.attachFootnoteService()

            await rig.withEntry {
                await #expect(throws: Boom.self) {
                    try await LifecycleEntry.run(kind: .close) { throw Boom() }
                }
                // The slot is free again as soon as `run` has thrown (read here: the harness resets it on the way out).
                #expect(LifecycleEntry.current == nil)
            }

            #expect(rig.entryEvents.first == .armed(.close), "the guard path ran")
            #expect(!rig.log.contains { $0.hasPrefix("tail:") })
            #expect(rig.editorState.lifecycleBarrier == nil)
            #expect(rig.sync.testWriterHandle?.testOpenBarrierSeq == nil, "N9: no barrier is open after a non-tail exit")
            #expect(rig.editorState.activeLifecycle == nil)
            footnotes.checkAndUpdateFootnotes(footnoteRefs: ["1"], projectId: rig.pid, fullContent: "x[^1]")
            #expect(footnotes.testHasPendingUpdate, "the service must be live again after a failed perform")
            footnotes.reset()
        }
    }
}
