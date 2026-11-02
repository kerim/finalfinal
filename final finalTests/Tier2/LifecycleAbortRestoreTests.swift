//
//  LifecycleAbortRestoreTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C5a (slice-3a-1b-everyday.md section 4.3 steps 4, 6, 7, 8 and section 7.2
//  "C5a"): what the abort routine gives back to a project that stays open, besides polling and block ids
//  (`LifecycleAbortTests`).
//
//    - C23: the sync services it suspended at arm replay what they recorded or had pending: a footnote debounce
//      pending at a cancelled close still produces its definition row
//    - the Markdown catch-up re-parse is actually SCHEDULED after an abort. P5's schedule-time gate drops a
//      re-parse scheduled while a token is armed, so the abort clears the token BEFORE asking for it; the test
//      puts the REAL scheduler behind the host and requires a task to exist, not just a host call
//    - the deferred rebuild requests (bibliography / Notes flags, queued footnote labels) are re-posted once
//      through the host, after the token is cleared; with nothing deferred the host is not asked
//    - Markdown's staged `switchInProgressContent` does not outlive the lifecycle
//    - `abortLifecycle` called directly: a whole-document save (FB) still queued is awaited, bounded
//
//  Harness: `LifecycleFlushHarness` (Helpers/). Entry-level tests nest under `LifecycleEntryStatic`, the
//  serialized parent of every suite that touches `LifecycleEntry`'s process-global state.
//

import Foundation
import SwiftUI
import Testing
@testable import final_final

private struct RestoreBoom: Error, Equatable {}

extension LifecycleEntryStatic {
    @Suite("LifecycleEntry abort restores the editor — Tier 2 (t-94369a83 3a-1b C5a)", .serialized, .timeLimit(.minutes(1)))
    @MainActor
    struct LifecycleAbortRestoreTests {

        private static let fresh = "# Alpha\n\nfresh Y paragraph.\n\n# Beta\n\nfour five six.\n"

        private func prime(_ rig: LifecycleFlushHarness) {
            rig.js.answer("flushPendingBlockChanges", true)
            rig.js.answer("hasBlockChanges", false)
            rig.fetchAnswer = Self.fresh
        }

        private func waitUntil(seconds: Double, _ condition: () throws -> Bool) async rethrows -> Bool {
            let clock = ContinuousClock()
            let end = clock.now.advanced(by: .seconds(seconds))
            while clock.now < end {
                if try condition() { return true }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return try condition()
        }

        // MARK: - C23: the sync services replay

        @Test("""
            C23: a cancelled close does not drop a footnote update that was pending at arm: the service is resumed \
            by the abort and the definition row for the new reference still reaches the database
            """)
        func cancelledClose_pendingFootnoteDebounce_stillProducesItsDefinitionRow() async throws {
            let seed = "Body[^1] and new[^2] text.\n\n# Notes\n\n[^1]: First note.\n"
            let rig = try LifecycleFlushHarness(content: seed)
            let footnotes = rig.attachFootnoteService()
            footnotes.checkAndUpdateFootnotes(footnoteRefs: ["1", "2"], projectId: rig.pid, fullContent: seed)
            #expect(footnotes.testHasPendingUpdate, "precondition: a debounced update is scheduled")
            #expect(try rig.notesDefinitions().keys.sorted() == ["1"], "precondition: only [^1] has a definition row")
            rig.controller.testSetIsPerforming(true)
            defer {
                rig.controller.testSetIsPerforming(false)
                footnotes.reset()
            }
            var outcome: LifecycleRunOutcome?

            try await rig.withEntry(bounds: LifecycleBounds.production.scaled(0.1)) {
                outcome = try await LifecycleEntry.run(kind: .close) { .close }
            }

            #expect(rig.entryEvents.first == .armed(.close), "the guard path ran")
            #expect(outcome == .cancelled)
            #expect(footnotes.testHasPendingUpdate, "the abort must have resumed the service: its update is scheduled again")
            let written = try await waitUntil(seconds: 6) { try rig.notesDefinitions().keys.contains("2") }
            #expect(written, "the definition row for [^2] must still be written; got \((try? rig.notesDefinitions()) ?? [:])")
        }

        // MARK: - Markdown: the catch-up re-parse is actually scheduled

        @Test("""
            Markdown: an abort schedules ONE catch-up re-parse that is actually SCHEDULED (the token is cleared \
            first, so P5's gate lets it through) and writes the editor state's content; polling restarts, nothing \
            is pushed (CodeMirror has no block ids) and the staged content is dropped
            """)
        func markdownAbort_schedulesTheCatchUpReparse_afterTheTokenIsCleared() async throws {
            let rig = try LifecycleFlushHarness()
            rig.editorState.editorMode = .source
            rig.editorState.sourceReparseDebounce = .milliseconds(30)
            // The text the editor state holds is deliberately DIFFERENT from what the lifecycle's own save wrote
            // (the fetch), so which write lands last shows that the catch-up ran.
            let caughtUp = "# Alpha\n\nCAUGHT UP paragraph.\n\n# Beta\n\nfour five six.\n"
            rig.editorState.content = caughtUp
            rig.fetchAnswer = Self.fresh
            rig.recordPushes()
            rig.reparseHandler = { [unowned rig] content in
                // The real scheduler, as ContentView's host installs it. The full-document branch reads the
                // project from the `DocumentManager` singleton at SCHEDULE time, so it is pointed at this rig for
                // the one synchronous call and put back before anything can suspend.
                let documentManager = DocumentManager.shared
                let priorDatabase = documentManager.projectDatabase
                let priorProjectId = documentManager.projectId
                documentManager.projectDatabase = rig.db
                documentManager.projectId = rig.pid
                defer {
                    documentManager.projectDatabase = priorDatabase
                    documentManager.projectId = priorProjectId
                }
                let services = ContentSyncServices(
                    sectionSync: SectionSyncService(),
                    annotationSync: AnnotationSyncService(),
                    bibliographySync: BibliographySyncService(),
                    footnoteSync: FootnoteSyncService(),
                    autoBackup: AutoBackupService(),
                    documentManager: documentManager,
                    scanMemo: MarkdownScanMemo()
                )
                ContentSyncObserverHost<EmptyView>.scheduleSourceModeReparse(
                    newValue: content, editorState: rig.editorState, services: services)
            }
            defer { rig.sync.stopPolling() }

            await rig.withEntry {
                _ = try? await LifecycleEntry.run(kind: .projectSwitch) { throw RestoreBoom() }
            }

            #expect(rig.entryEvents.first == .armed(.projectSwitch), "the guard path ran")
            #expect(rig.sync.testWriterLedger.lifecycleWholeDocumentApplied == 1, "precondition: FB wrote CodeMirror's text")
            #expect(rig.reparseRequests.count == 1, "exactly one catch-up re-parse is requested")
            let request = try #require(rig.reparseRequests.first)
            #expect(request.content == caughtUp)
            #expect(!request.lifecycleStillArmed, "the token must be cleared BEFORE the host is asked (P5 drops it while armed)")
            let task = try #require(
                rig.editorState.blockReparseTask,
                "P5's schedule-time gate dropped the catch-up: no re-parse Task exists")
            await task.value
            // Phase 4a (t-94369a83): the fire now saves BLOCK BY BLOCK through the write queue (this rig has a writer),
            // so the fire's Task returns as soon as the turn is reserved and the write itself is the writer's in-flight
            // Task. Wait for that too (the same `while let` wait the next fire and `writeNow` use).
            while let pending = rig.editorState.markdownWriter.inFlight {
                await pending.value
            }
            let texts = try rig.paragraphTexts()
            #expect(texts.contains("CAUGHT UP paragraph."), "the catch-up re-parse must write; got \(texts)")
            #expect(
                rig.editorState.markdownWriter.lastTimingLine?.contains("outcome=applied") == true,
                "the catch-up went through the writer (not the legacy whole-document write)")
            #expect(!texts.contains("fresh Y paragraph."))
            #expect(rig.pushes.isEmpty, "Markdown has no block ids to restore")
            #expect(rig.sync.testPollTimerIsArmed, "polling restarts in both modes")
            #expect(rig.editorState.switchInProgressContent == nil, "the staged Markdown content must not outlive the lifecycle")
            #expect(rig.editorState.lifecycleFlushDoneFor == nil)
            #expect(rig.editorState.activeLifecycle == nil)
            #expect(rig.editorState.lifecycleBarrier == nil)
        }

        @Test("Rich Text: the abort asks for NO catch-up re-parse (that is Markdown's only)")
        func richTextAbort_requestsNoReparse() async throws {
            let rig = try LifecycleFlushHarness()
            prime(rig)
            rig.recordPushes()
            defer { rig.sync.stopPolling() }

            await rig.withEntry {
                _ = try? await LifecycleEntry.run(kind: .close) { throw RestoreBoom() }
            }

            #expect(rig.entryEvents.first == .armed(.close), "the guard path ran")
            #expect(rig.pushes.count == 1, "precondition: the abort ran its Rich Text restore")
            #expect(rig.reparseRequests.isEmpty)
        }

        // MARK: - Deferred rebuilds

        @Test("""
            deferred rebuild requests are RE-POSTED once through the host after an abort, with the token already \
            cleared (the idle drain posts through the main queue, and the handlers refuse while armed)
            """)
        func deferredRebuildFlags_areRePosted() async throws {
            let rig = try LifecycleFlushHarness()
            prime(rig)
            rig.recordPushes()
            defer { rig.sync.stopPolling() }

            await rig.withEntry {
                _ = try? await LifecycleEntry.run(kind: .projectSwitch) {
                    // What the three rebuild handlers do while armed (round C4): keep the request.
                    rig.editorState.pendingBibliographyRebuild = true
                    rig.editorState.pendingNotesRebuild = true
                    rig.editorState.pendingFootnoteLabels.enqueue("3")
                    throw RestoreBoom()
                }
            }

            #expect(rig.entryEvents.first == .armed(.projectSwitch), "the guard path ran")
            #expect(rig.repostCalls == [false], "re-posted exactly once, after the token was cleared; calls: \(rig.repostCalls)")
            #expect(rig.editorState.pendingBibliographyRebuild, "the abort never drops a flag itself: the host's idle drain consumes it")
        }

        @Test("with nothing deferred the abort does not ask the host to re-post (control for the test above)")
        func noDeferredRebuilds_nothingIsReposted() async throws {
            let rig = try LifecycleFlushHarness()
            prime(rig)
            rig.recordPushes()
            defer { rig.sync.stopPolling() }

            await rig.withEntry {
                _ = try? await LifecycleEntry.run(kind: .projectSwitch) { throw RestoreBoom() }
            }

            #expect(rig.entryEvents.first == .armed(.projectSwitch), "the guard path ran")
            #expect(rig.pushes.count == 1, "precondition: the abort ran")
            #expect(rig.repostCalls.isEmpty)
        }

        // MARK: - abortLifecycle called directly: FB still queued

        @Test("""
            FB still queued when the abort starts: the abort awaits FB's own task (bounded), then re-pushes ids \
            before restarting polling
            """)
        func fbStillQueued_isAwaited_thenIdsAreRepushed() async throws {
            let rig = try LifecycleFlushHarness()
            rig.recordPushes()
            defer { rig.sync.stopPolling() }
            guard case .armed(let token) = rig.editorState.armLifecycle(.close, wasGettingStarted: false) else {
                Issue.record("could not arm a close token")
                return
            }
            let fbGate = LifecycleEntryHarness.Gate()
            var flush = LifecycleFlushResult()
            flush.fbStatus = .started
            flush.fbTask = Task<LifecycleFBOutcome, Never> { @MainActor in
                await fbGate.wait()
                return .applied
            }
            let opener = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                fbGate.open()
            }

            await rig.editorState.abortLifecycle(
                token: token,
                reason: .performFailed(RestoreBoom()),
                host: rig.host,
                flush: flush,
                bounds: LifecycleBounds.production.scaled(0.25)
            )
            await opener.value

            #expect(rig.pushes.count == 1, "FB landed during the bounded wait, so the ids are restored")
            #expect(rig.pushes.first?.pollTimerArmed == false, "before polling restarts")
            #expect(rig.sync.testPollTimerIsArmed)
            #expect(rig.editorState.activeLifecycle == nil)
        }

        @Test("FB that never settles cannot hold the abort: it returns within its bound, with no re-push, polling restarted, token nil")
        func fbNeverSettles_abortStillReturnsWithinItsBound() async throws {
            let rig = try LifecycleFlushHarness()
            rig.recordPushes()
            guard case .armed(let token) = rig.editorState.armLifecycle(.close, wasGettingStarted: false) else {
                Issue.record("could not arm a close token")
                return
            }
            let fbGate = LifecycleEntryHarness.Gate()
            defer {
                fbGate.open()
                rig.sync.stopPolling()
            }
            var flush = LifecycleFlushResult()
            flush.fbStatus = .started
            flush.fbTask = Task<LifecycleFBOutcome, Never> { @MainActor in
                await fbGate.wait()
                return .applied
            }
            let clock = ContinuousClock()

            let start = clock.now
            await rig.editorState.abortLifecycle(
                token: token,
                reason: .performFailed(RestoreBoom()),
                host: rig.host,
                flush: flush,
                bounds: LifecycleBounds.production.scaled(0.1)
            )
            let elapsed = clock.now - start

            #expect(elapsed < .seconds(1.4), "bounded by abortStep (0.2s at this scale): \(elapsed)")
            #expect(rig.pushes.isEmpty, "an unsettled FB is not known to have applied: nothing is pushed")
            #expect(rig.sync.testPollTimerIsArmed, "polling restarts regardless")
            #expect(rig.editorState.activeLifecycle == nil)
        }
    }
}
