//
//  LifecycleFlushGuardTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C3a (slice-3a-1b-everyday.md section 4.2 steps 0-3, section 7.2 "C3a"):
//  what happens BEFORE F in `EditorViewState.runLifecycleFlush`.
//
//    - step 0: polling is stopped and the Markdown re-parse task is cancelled (both modes)
//    - step 1: the section-operation wait. A running operation that clears in time lets the sequence
//      proceed; one that never clears makes a CLOSE/SWITCH return `.cancelledSectionOperation` having
//      reserved nothing, and makes a QUIT continue with `opStillRunning` (F runs, FB does not)
//    - step 2 (N24): the editor is captured AFTER that guard, so a mode toggle that finishes during the
//      wait is what is captured
//    - step 3: every running rebuild task is awaited to completion (its push lands before F), bounded
//
//  Real clocks, short: the guard tests pass `LifecycleBounds.scaled(_:)` so the section-operation bound is
//  0.6s (close) or 1.0s (quit), against operations that clear at 0.15s.
//

import Foundation
import Testing
import WebKit
@testable import final_final

@Suite("Lifecycle save sequence, guard and rebuild wait — Tier 2 (t-94369a83 3a-1b C3a)", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct LifecycleFlushGuardTests {

    private static let fresh = "# Alpha\n\nfresh Y paragraph.\n\n# Beta\n\nfour five six.\n"

    /// How the test makes a section operation look "still running".
    enum OperationSignal: CaseIterable, CustomTestStringConvertible {
        case controllerIsPerforming
        case contentStateIsStructuralUndo

        var testDescription: String {
            switch self {
            case .controllerIsPerforming: "StructuralUndoController.isPerforming"
            case .contentStateIsStructuralUndo: "contentState == .structuralUndo"
            }
        }
    }

    private func beginOperation(_ signal: OperationSignal, _ rig: LifecycleFlushHarness) {
        switch signal {
        case .controllerIsPerforming: rig.controller.testSetIsPerforming(true)
        case .contentStateIsStructuralUndo: rig.editorState.contentState = .structuralUndo
        }
    }

    private func endOperation(_ signal: OperationSignal, _ rig: LifecycleFlushHarness) {
        switch signal {
        case .controllerIsPerforming: rig.controller.testSetIsPerforming(false)
        case .contentStateIsStructuralUndo: rig.editorState.contentState = .idle
        }
        rig.note("operation cleared")
    }

    // MARK: - Step 0

    @Test("Step 0: polling is stopped and the Markdown re-parse task is cancelled, before anything else")
    func armStopsPollingAndCancelsTheReparse() async throws {
        let rig = try LifecycleFlushHarness()
        rig.js.answer("flushPendingBlockChanges", true)
        rig.js.answer("hasBlockChanges", false)
        rig.fetchAnswer = Self.fresh
        rig.sync.startPolling()
        #expect(rig.sync.testPollTimerIsArmed, "precondition: the poll timer is running")
        let reparse = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
        rig.editorState.blockReparseTask = reparse

        _ = await rig.run()

        #expect(!rig.sync.testPollTimerIsArmed, "step 0 must stop polling (and the sequence must not restart it)")
        #expect(reparse.isCancelled, "step 0 must cancel the pending re-parse, in both modes")
        #expect(rig.editorState.blockReparseTask == nil)
    }

    // MARK: - Step 1: close / switch

    @Test("Step 1: a section operation that clears at 0.15s lets a close proceed to FB", arguments: OperationSignal.allCases)
    func closeProceeds_whenTheOperationClearsInTime(signal: OperationSignal) async throws {
        let rig = try LifecycleFlushHarness()
        rig.js.answer("flushPendingBlockChanges", true)
        rig.js.answer("hasBlockChanges", false)
        rig.fetchAnswer = Self.fresh
        beginOperation(signal, rig)
        let clearer = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            self.endOperation(signal, rig)
        }

        let result = await rig.run(.close, bounds: LifecycleBounds.production.scaled(0.2))
        await clearer.value

        #expect(result.outcome == .flushed)
        #expect(!result.opStillRunning)
        #expect(result.fbOutcome == .applied)
        #expect(try rig.paragraphTexts().contains("fresh Y paragraph."))
        let cleared = try #require(rig.log.firstIndex(of: "operation cleared"))
        let captured = try #require(rig.log.firstIndex(of: "activeWebView"))
        #expect(cleared < captured, "N24: the editor is captured only AFTER the guard cleared; log: \(rig.log)")
    }

    @Test("Step 1: a section operation that never clears makes a close return cancelled, with nothing polled, fetched or reserved",
          arguments: OperationSignal.allCases)
    func closeIsCancelled_whenTheOperationNeverClears(signal: OperationSignal) async throws {
        let rig = try LifecycleFlushHarness()
        rig.js.answer("flushPendingBlockChanges", true)
        rig.js.answer("hasBlockChanges", false)
        rig.fetchAnswer = Self.fresh
        let frontierBefore = try #require(rig.sync.testWriterHandle).testFrontier
        beginOperation(signal, rig)
        defer { endOperation(signal, rig) }

        let result = await rig.run(.close, bounds: LifecycleBounds.production.scaled(0.2))

        #expect(result.outcome == .cancelledSectionOperation)
        #expect(result.fbStatus == .notReached)
        #expect(result.fbTask == nil)
        #expect(result.capturedEditorMode == nil, "a cancelled close captured nothing")
        #expect(rig.log.isEmpty, "no JS call, no capture, no fetch may have happened; log: \(rig.log)")
        // B21: no `.lifecycleWholeDocument` reservation was ever made (a reserved FB would have applied or been lost).
        let events = rig.writerEvents.events
        #expect(!events.contains { if case .systemApplied = $0 { return true }; return false },
                "no system write may have been reserved or applied; events: \(events)")
        #expect(!events.contains { if case .lifecycleWholeDocumentLost = $0 { return true }; return false })
        #expect(rig.sync.testWriterLedger.lifecycleWholeDocumentApplied == 0)
        #expect(rig.sync.testWriterLedger.lifecycleWholeDocumentLost == 0)
        #expect(try #require(rig.sync.testWriterHandle).testFrontier == frontierBefore)
        #expect(try rig.paragraphTexts().contains("one two three."), "the database must be untouched")
    }

    // MARK: - Step 1: quit

    @Test("Step 1: a quit whose section operation never clears CONTINUES: F runs, opStillRunning is set, FB is not attempted")
    func quitContinues_withOpStillRunning_noFB() async throws {
        let rig = try LifecycleFlushHarness()
        rig.js.answer("flushPendingBlockChanges", true)
        rig.js.answer("hasBlockChanges", false)
        rig.fetchAnswer = Self.fresh
        rig.editorState.contentState = .structuralUndo
        defer { rig.editorState.contentState = .idle }

        let result = await rig.run(.quit, bounds: LifecycleBounds.production.scaled(0.1))

        #expect(result.outcome == .flushed, "a quit never gives up on its save")
        #expect(result.opStillRunning)
        #expect(result.fbStatus == .skippedOpStillRunning, "FB would undo the running operation")
        #expect(result.fbTask == nil)
        #expect(rig.log.contains("poll"), "F must still send the user's typing; log: \(rig.log)")
        #expect(rig.sync.testWriterLedger.lifecycleWholeDocumentApplied == 0)
        #expect(rig.sync.testWriterLedger.lifecycleWholeDocumentLost == 0, "skipping FB for a running operation is not a loss")
        #expect(try rig.paragraphTexts().contains("one two three."), "FB did not run, so the database keeps the operation's rows")
    }

    // MARK: - Step 2: capture after the guard (N24)

    @Test("Step 2 (N24): a mode toggle that finishes DURING the guard is what the sequence captures")
    func captureIsTakenAfterTheGuard_soAModeToggleDuringTheWaitIsSeen() async throws {
        let rig = try LifecycleFlushHarness()
        rig.js.answer("flushPendingBlockChanges", true)
        rig.js.answer("hasBlockChanges", false)
        rig.fetchAnswer = Self.fresh
        rig.editorState.editorMode = .source
        rig.editorState.contentState = .structuralUndo
        let toggler = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            rig.editorState.editorMode = .wysiwyg
            rig.editorState.contentState = .idle
        }

        let result = await rig.run(.close, bounds: LifecycleBounds.production.scaled(0.2))
        await toggler.value

        #expect(result.capturedEditorMode == .wysiwyg, "the mode read before the guard (.source) is stale by the time it clears")
        #expect(result.fbOutcome == .applied, "the Rich Text branch must have run on the post-guard mode")
    }

    // MARK: - Step 3: running rebuilds

    @Test("Step 3: a rebuild task running at arm is awaited, and its push lands BEFORE F's first poll")
    func runningRebuild_isAwaited_andLandsBeforeF() async throws {
        let rig = try LifecycleFlushHarness()
        rig.js.answer("flushPendingBlockChanges", true)
        rig.js.answer("hasBlockChanges", false)
        rig.fetchAnswer = Self.fresh
        let gate = LifecycleEntryHarness.Gate()
        rig.editorState.registerRebuildTask(Task { @MainActor in
            await gate.wait()
            rig.note("rebuild push landed")
        })
        #expect(rig.editorState.runningRebuildTasks.count == 1)

        let sequence = Task { @MainActor in await rig.run() }
        // The rebuild holds the sequence: give it ample time to wrongly go ahead.
        try await Task.sleep(for: .milliseconds(150))
        #expect(!rig.log.contains("poll"), "F must not start while a rebuild is still running; log: \(rig.log)")
        gate.open()
        let result = await sequence.value

        #expect(result.outcome == .flushed)
        #expect(!result.rebuildWaitTimedOut)
        let push = try #require(rig.log.firstIndex(of: "rebuild push landed"))
        let firstPoll = try #require(rig.log.firstIndex(of: "poll"))
        #expect(push < firstPoll, "the rebuild's push must land before F; log: \(rig.log)")
        #expect(rig.editorState.runningRebuildTasks.isEmpty, "a finished rebuild removes itself from the collection")
        #expect(result.fbOutcome == .applied)
    }

    @Test("Step 3: every running rebuild is awaited (item 21: a collection, not one slot)")
    func everyRunningRebuild_isAwaited() async throws {
        let rig = try LifecycleFlushHarness()
        rig.js.answer("flushPendingBlockChanges", true)
        rig.js.answer("hasBlockChanges", false)
        rig.fetchAnswer = Self.fresh
        let gateA = LifecycleEntryHarness.Gate()
        let gateB = LifecycleEntryHarness.Gate()
        rig.editorState.registerRebuildTask(Task { @MainActor in await gateA.wait(); rig.note("rebuild A landed") })
        rig.editorState.registerRebuildTask(Task { @MainActor in await gateB.wait(); rig.note("rebuild B landed") })
        #expect(rig.editorState.runningRebuildTasks.count == 2)

        let sequence = Task { @MainActor in await rig.run() }
        try await Task.sleep(for: .milliseconds(50))
        gateA.open()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!rig.log.contains("poll"), "one rebuild is still running, so F must still be waiting; log: \(rig.log)")
        gateB.open()
        let result = await sequence.value

        #expect(result.outcome == .flushed)
        let firstPoll = try #require(rig.log.firstIndex(of: "poll"))
        #expect(try #require(rig.log.firstIndex(of: "rebuild A landed")) < firstPoll)
        #expect(try #require(rig.log.firstIndex(of: "rebuild B landed")) < firstPoll)
    }

    @Test("Step 3: a rebuild that never finishes does not hold the sequence past its bound")
    func aRebuildThatNeverFinishes_isWaitedForOnlyUpToItsBound() async throws {
        let rig = try LifecycleFlushHarness()
        rig.js.answer("flushPendingBlockChanges", true)
        rig.js.answer("hasBlockChanges", false)
        rig.fetchAnswer = Self.fresh
        let neverOpened = LifecycleEntryHarness.Gate()
        rig.editorState.registerRebuildTask(Task { @MainActor in await neverOpened.wait() })

        // 0.05x: rebuild wait 0.4s, close total 0.75s.
        let result = await rig.run(.close, bounds: LifecycleBounds.production.scaled(0.05))

        #expect(result.rebuildWaitTimedOut)
        #expect(result.outcome == .flushed, "an overrunning rebuild is accepted as an orphan, the save goes on")
        #expect(rig.log.contains("poll"), "F must run after the bound; log: \(rig.log)")
        neverOpened.open()
    }
}
