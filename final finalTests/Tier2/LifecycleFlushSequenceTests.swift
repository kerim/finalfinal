//
//  LifecycleFlushSequenceTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C3a (slice-3a-1b-everyday.md section 4.2 steps 0-6, section 7.2 "C3a"):
//  the first half of the lifecycle save sequence for Rich Text, `EditorViewState.runLifecycleFlush`, driven
//  directly (nothing in the app calls it yet). These tests pin the data path: F (drain + forced poll), the
//  fresh fetch and its fallbacks, and FB (the queued whole-document write).
//
//    - U2(a): fresh content Y over stale `editorState.content` -> the DB has Y, FB applied once
//    - U2(b): a wedged poll -> FB is still applied (with the fallback content), the fetch is skipped
//    - U8: the sequence's captured WebView survives every other reference being released
//    - an empty fetch ("") is VALID: no FB, no fallback, and the user blocks the forced poll deleted stay
//      deleted (the seed `editorState.content` is NON-empty, otherwise the test would be vacuous)
//    - E1: an FB that loses its race is neither a failure nor a loss, and is never cancelled
//    - a zoomed-without-range FB is refused and counted as a loss (`.refused(.notWanted)`)
//    - step 6b: section sync runs when not zoomed and not `opStillRunning`
//
//  Harness: `LifecycleFlushHarness` (Helpers/), over the `BlockSyncPollWatchdogTests` scripted-JS pattern.
//

import Foundation
import Testing
import WebKit
@testable import final_final

@Suite("Lifecycle save sequence, steps 0-6 — Tier 2 (t-94369a83 3a-1b C3a)", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct LifecycleFlushSequenceTests {

    private static let fresh = "# Alpha\n\nfresh Y paragraph.\n\n# Beta\n\nfour five six.\n"

    // MARK: - U2(a)

    @Test("U2(a): fresh content Y fetched over a stale editorState.content is what the database ends with (FB applied once)")
    func freshContentOverStaleContent_isWrittenThroughFB() async throws {
        let rig = try LifecycleFlushHarness()
        rig.js.answer("flushPendingBlockChanges", true)
        rig.js.answer("hasBlockChanges", false)
        rig.fetchAnswer = Self.fresh                                  // the editor's live document
        #expect(rig.editorState.content == LifecycleFlushHarness.seed, "precondition: the content on hand is stale")

        let result = await rig.run()

        #expect(result.outcome == .flushed)
        #expect(result.fetchedContent == Self.fresh)
        #expect(!result.usedFallback)
        #expect(result.fbStatus == .started)
        #expect(result.fbOutcome == .applied, "FB must settle inside its 2s race in this healthy case")
        #expect(rig.sync.testWriterLedger.lifecycleWholeDocumentApplied == 1)
        #expect(rig.sync.testWriterLedger.lifecycleWholeDocumentLost == 0)
        let texts = try rig.paragraphTexts()
        #expect(texts.contains("fresh Y paragraph."), "the fresh content must be in the database; got \(texts)")
        #expect(!texts.contains("one two three."), "the stale paragraph must be gone; got \(texts)")
        // F ran before the fetch: the forced poll's JS calls precede getContent.
        let firstFetch = try #require(rig.log.firstIndex(of: "fetch"))
        let firstPoll = try #require(rig.log.firstIndex(of: "poll"))
        #expect(firstPoll < firstFetch)
        #expect(rig.sync.testPollTimerIsArmed == false, "step 0 stopped polling, and the sequence must not restart it")
    }

    // MARK: - U2(b)

    @Test("""
        U2(b): a poll cycle wedged inside a JS call is ended by its watchdog, the fetch is skipped, and FB is STILL \
        applied, with the fallback content (margins: 0.2s watchdog against an 8s drain bound)
        """)
    func wedgedPoll_stillAppliesFB_withFallbackContent() async throws {
        let rig = try LifecycleFlushHarness()
        rig.js.answer("hasBlockChanges", false)
        rig.js.wedgeOn("hasBlockChanges")
        rig.fetchAnswer = "THE FETCH MUST NOT HAPPEN"
        let fallback = "# Alpha\n\nfallback paragraph.\n\n# Beta\n\nfour five six.\n"
        rig.editorState.content = fallback

        let sync = rig.sync
        let cycle = Task { @MainActor in await sync.pollBlockChangesForTest(force: false) }
        await rig.js.waitUntilEnteredWedge()

        let result = await rig.run()

        #expect(result.watchdogHit, "the drain must report that the in-flight cycle ended at its own watchdog")
        #expect(result.usedFallback, "after a watchdog hit the content on hand is the fallback")
        #expect(result.fetchedContent == nil)
        #expect(!rig.log.contains("fetch"), "the fetch is skipped after a watchdog hit; log: \(rig.log)")
        #expect(result.fbOutcome == .applied, "FB must still be applied after a wedged poll")
        #expect(rig.sync.testWriterLedger.lifecycleWholeDocumentApplied == 1)
        #expect(try rig.paragraphTexts().contains("fallback paragraph."))

        try await rig.releaseWedgeAndSettle()
        await cycle.value
    }

    // MARK: - U8

    @Test("""
        U8: the WebView the sequence captured after the guard is what it fetches from and polls, even though the \
        service's own view reference is nil and the harness released the captured one right after handing it over
        """)
    func capturedWebView_survivesEveryOtherReferenceBeingReleased() async throws {
        let rig = try LifecycleFlushHarness()
        rig.js.answer("flushPendingBlockChanges", true)
        rig.js.answer("hasBlockChanges", false)
        rig.fetchAnswer = Self.fresh
        // The service's own view reference is cleared by a DEBUG seam (no waiting for ARC); the host hands
        // out a DIFFERENT view, which the sequence alone keeps alive once the harness lets go of it.
        rig.swapHostView(to: LifecycleFlushHarness.makeView())
        rig.clearServiceOwnView()
        rig.dropOwnViewReferenceOnCapture = true
        #expect(rig.serviceOwnViewIsNil, "precondition: the service's own view reference must be nil")

        let result = await rig.run()

        #expect(rig.hostView == nil, "precondition: the harness handed its only reference over")
        #expect(rig.viewAliveAtFetch == true, "the sequence's own strong capture must keep the view alive for the fetch")
        #expect(result.fetchedContent == Self.fresh,
                "the fetch must have asked the CAPTURED view (the service's own is nil, so its default path returns nil)")
        #expect(!result.usedFallback)
        #expect(rig.log.contains("poll"), "F must have polled the captured view; log: \(rig.log)")
        #expect(result.fbOutcome == .applied)
    }

    // MARK: - Empty fetch is valid

    @Test("""
        An empty fetch ("") is VALID (select all, delete, close): no fallback, no FB, and the paragraphs F deleted \
        stay deleted, although editorState.content on hand is NON-empty
        """)
    func emptyFetch_isValid_noFB_userBlocksStayDeleted() async throws {
        let rig = try LifecycleFlushHarness()
        let before = try rig.blocks()
        let paragraphIds = before.filter { $0.blockType == .paragraph }.map(\.id)
        #expect(paragraphIds.count == 2, "precondition: the seed has two paragraphs")
        #expect(!rig.editorState.content.isEmpty, "precondition: the stale content on hand is NON-empty")
        // The forced poll carries the user's deletion of both paragraphs (2 of 4 blocks: not a 100% delete).
        rig.js.answer("flushPendingBlockChanges", true)
        rig.js.answer("hasBlockChanges", true)
        rig.js.answer("getBlockChanges", try blockChangesJSON(deletes: paragraphIds))
        rig.fetchAnswer = ""

        let result = await rig.run()

        #expect(result.outcome == .flushed)
        #expect(result.fetchedContent == "", "an empty fetch is a valid fetch")
        #expect(!result.usedFallback, "the stale non-empty content must NOT stand in for a valid empty fetch")
        #expect(result.fbStatus == .skippedEmptyContent)
        #expect(result.fbOutcome == nil)
        #expect(rig.sync.testWriterLedger.lifecycleWholeDocumentApplied == 0)
        #expect(rig.sync.testWriterLedger.lifecycleWholeDocumentLost == 0, "an empty document is nothing to save, not a loss")
        let texts = try rig.paragraphTexts()
        #expect(texts.isEmpty, "F must have deleted the user blocks and nothing may bring them back; got \(texts)")
    }

    // MARK: - Fallback

    @Test("A fetch that returns nothing (nil) falls back to editorState.content, and FB writes that")
    func nilFetch_fallsBackToContentOnHand() async throws {
        let rig = try LifecycleFlushHarness()
        rig.js.answer("flushPendingBlockChanges", true)
        rig.js.answer("hasBlockChanges", false)
        rig.fetchAnswer = nil
        let onHand = "# Alpha\n\non-hand paragraph.\n\n# Beta\n\nfour five six.\n"
        rig.editorState.content = onHand

        let result = await rig.run()

        #expect(result.usedFallback)
        #expect(result.fetchedContent == nil)
        #expect(result.fbOutcome == .applied)
        #expect(try rig.paragraphTexts().contains("on-hand paragraph."))
    }

    // MARK: - E1: FB losing its race

    @Test("""
        E1: an FB that loses its race is not a failure and not a loss: the sequence continues, the race never \
        cancels FB's task, and FB lands once the writer reaches its turn
        """)
    func fbLosingItsRace_isNotALoss_andIsNeverCancelled() async throws {
        let rig = try LifecycleFlushHarness()
        rig.js.answer("flushPendingBlockChanges", true)
        rig.js.answer("hasBlockChanges", false)
        rig.fetchAnswer = Self.fresh
        // An editor sequence reserved and never settled: FB is queued behind it and cannot start.
        let blocker = try #require(rig.sync.testWriterHandle).reserve()

        // 0.1x: FB race = 0.2s; the whole run stays under 2s.
        let result = await rig.run(.close, bounds: LifecycleBounds.production.scaled(0.1))

        #expect(result.outcome == .flushed, "losing the FB race must not abort the sequence")
        #expect(result.fbStatus == .started)
        #expect(result.fbOutcome == nil, "FB cannot have settled yet: it is queued behind the unsettled sequence")
        #expect(rig.sync.testWriterLedger.lifecycleWholeDocumentLost == 0, "losing the race is NOT a loss (E1)")
        #expect(rig.sync.testLifecycleLossReports == 0)
        let fbTask = try #require(result.fbTask)
        #expect(!fbTask.isCancelled, "the race must never cancel FB's task")

        blocker.settleIfOpen(.noBatch)
        let settled = await fbTask.value

        #expect(settled == .applied, "FB must still land once its turn comes")
        #expect(rig.sync.testWriterLedger.lifecycleWholeDocumentApplied == 1)
        #expect(rig.sync.testWriterLedger.lifecycleWholeDocumentLost == 0)
        #expect(try rig.paragraphTexts().contains("fresh Y paragraph."))
    }

    // MARK: - Zoomed without a range

    @Test("A zoomed editor with no block range yet: FB is refused (.notWanted), counted as a loss, and nothing is written")
    func zoomedWithoutRange_isRefusedAndCountedLost() async throws {
        let rig = try LifecycleFlushHarness()
        rig.js.answer("flushPendingBlockChanges", true)
        rig.js.answer("hasBlockChanges", false)
        rig.fetchAnswer = Self.fresh
        let alpha = try #require(try rig.blocks().first { $0.blockType == .heading && $0.textContent == "Alpha" })
        rig.editorState.zoomedSectionId = alpha.id
        #expect(rig.editorState.zoomedBlockRange == nil)

        let result = await rig.run()

        guard case .lost = result.fbOutcome else {
            Issue.record("a zoomed-without-range refusal must be reported as a loss; got \(String(describing: result.fbOutcome))")
            return
        }
        #expect(rig.sync.testWriterLedger.lifecycleWholeDocumentLost == 1)
        #expect(rig.sync.testWriterLedger.lifecycleWholeDocumentApplied == 0)
        #expect(try rig.paragraphTexts().contains("one two three."), "the refusal must leave the database untouched")
    }

    // MARK: - Step 6b

    @Test("Step 6b: section sync runs after FB when not zoomed (the new heading reaches the Section table)")
    func sectionSync_runsAfterFB_whenNotZoomed() async throws {
        let rig = try LifecycleFlushHarness()
        let sections = SectionSyncService()
        sections.configure(database: rig.db, projectId: rig.pid)
        rig.editorState.sectionSyncService = sections
        rig.js.answer("flushPendingBlockChanges", true)
        rig.js.answer("hasBlockChanges", false)
        rig.fetchAnswer = Self.fresh + "\n# Gamma\n\nnew section.\n"

        let result = await rig.run()

        #expect(result.fbOutcome == .applied)
        let titles = try rig.db.fetchSections(projectId: rig.pid).map(\.title)
        #expect(titles.contains("Gamma"), "6b must have synced the fresh content's headings; got \(titles)")
        // `editorState.sectionSyncService` is weak: keep the local alive to here, whatever the optimizer does.
        withExtendedLifetime(sections) {}
    }
}
