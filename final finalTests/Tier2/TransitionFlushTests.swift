//
//  TransitionFlushTests.swift
//  final finalTests
//
//  Phase 5 job A7 (design: docs/architecture/write-queue-plan/phase5/a7-a10-design.md, sections 0, 1, 5 and 7): the Swift side of the
//  carried zoom, driven with a REAL `BlockSyncService` and `DocumentWriter` whose page calls go through `testJSEvaluator` (no web page).
//  The page's answers (`beginTransition`, `swapTransition`, `endTransition`) are scripted; what these tests pin is what Swift does with
//  them, in the sync model's order:
//    - TransBegin + TransLiveRead + TransBarrier: the begin's batch is written through the queue BEFORE `contentGeneration` moves (F8);
//      the barrier waits for a write reserved earlier, and on its bound the hold is ended and the zoom abandoned (nothing changed);
//    - a begin the page cannot answer leaves nothing held and hands the zoom back to today's path;
//    - TransPushFrom + TransReplay: the zoom out swaps the rows' whole document in, clears the zoom, and is `.idle` again; the zoom in's
//      `outside` batch is written AFTER `.idle`;
//    - a refused swap: the held typing is written, then the rows are pushed the old way (the catch-up);
//    - the holds: Cmd-/ during a zoom is held and asked again when the zoom is over; a zoom held behind a switch runs when it is over, the
//      newest press replacing an older one, and is dropped when a close starts.
//

import Foundation
import GRDB
import Testing
import WebKit
@testable import final_final

/// A temporary project, a configured block-sync service and editor state, and a scripted page.
@MainActor
final class TransitionRig {
    let db: ProjectDatabase
    let pid: String
    let sync = BlockSyncService()
    let editorState = EditorViewState()
    let view = WKWebView()
    /// Every page call, in order.
    var scripts: [String] = []
    /// What the next `beginTransition()` answers (a JSON object), or nil to throw.
    var beginAnswer: String? = #"{"ok":true,"token":7,"batch":{"updates":[],"inserts":[],"deletes":[]}}"#
    /// What `swapTransition` answers.
    var swapAnswer = #"{"ok":true,"replayed":0,"dropped":0,"outside":{"updates":[],"inserts":[],"deletes":[]}}"#
    /// `contentGeneration` at the moment the begin's batch reached the database (read by the swap answer).
    var generationAtSwap: Int?
    /// `contentState` when the swap was asked.
    var stateAtSwap: EditorContentState?
    /// Pushes the catch-up made the old way (`setContentWithBlockIds`).
    var oldWayPushes: [String] = []

    struct BeginThrew: Error {}

    init(markdown: String) throws {
        db = try TestFixtureFactory.createTemporary(content: markdown)
        pid = try TestFixtureFactory.getProjectId(from: db)
        sync.configure(database: db, projectId: pid, webView: view)
        sync.editorState = editorState
        editorState.toastCenter = ToastCenter()
        editorState.blockSyncService = sync
        editorState.projectDatabase = db
        editorState.currentProjectId = pid
        editorState.content = markdown
        editorState.sections = try blocks().filter { $0.blockType == .heading }.map { SectionViewModel(from: $0) }
        sync.testJSEvaluator = { [weak self] script in try await self?.answer(script) }
        sync.testSetContentHook = { [weak self] markdown, _, _, _ in
            self?.oldWayPushes.append(markdown)
            return nil
        }
        sync.testPushBlockIdsHook = { _ in }
    }

    func blocks() throws -> [Block] { try db.fetchBlocks(projectId: pid).sorted { $0.sortOrder < $1.sortOrder } }

    func block(startingWith text: String) throws -> Block {
        guard let found = try blocks().first(where: { $0.markdownFragment.hasPrefix(text) }) else {
            throw BeginThrew()
        }
        return found
    }

    /// A batch that rewrites the block starting with `text` to `newText`, as the page reports it.
    func updateJSON(_ id: String, _ newText: String) -> String {
        #"{"updates":[{"id":"\#(id)","textContent":"\#(newText)","markdownFragment":"\#(newText)"}],"inserts":[],"deletes":[]}"#
    }

    private func answer(_ script: String) async throws -> Any? {
        scripts.append(script)
        if script.contains("beginTransition") {
            guard let beginAnswer else { throw BeginThrew() }
            return beginAnswer
        }
        if script.contains("swapTransition") {
            generationAtSwap = editorState.contentGeneration
            stateAtSwap = editorState.contentState
            return swapAnswer
        }
        if script.contains("endTransition") { return #"{"ended":true}"# }
        if script.contains("getContent") { return editorState.content }
        if script.contains("hasBlockChanges") { return false }
        if script.contains("confirmBlockIds") { return true }
        return nil
    }

    /// The scripts that named `name`, in order.
    func calls(_ name: String) -> [String] { scripts.filter { $0.contains(name) } }
}

private let book = """
# Chapter One

First paragraph.

# Chapter Two

Second paragraph.
"""

@Suite("Phase 5 A7: the carried zoom's Swift side")
@MainActor
struct TransitionFlushTests {

    @Test("TransBegin + TransBarrier: the begin's batch is in the rows before the state leaves .idle (F8)")
    func beginBatchIsWrittenBeforeTheGenerationMoves() async throws {
        let rig = try TransitionRig(markdown: book)
        let first = try rig.block(startingWith: "First paragraph")
        rig.beginAnswer = #"{"ok":true,"token":3,"batch":"# + rig.updateJSON(first.id, "First paragraph. typed") + "}"
        let generation = rig.editorState.contentGeneration
        let start = await rig.editorState.beginZoomTransition(rig.sync, label: "test")
        #expect(start == .ready(token: 3))
        // Step 3 done, step 4 not yet: the typing is in the rows and nothing has left .idle.
        #expect(try rig.block(startingWith: "First paragraph").markdownFragment == "First paragraph. typed")
        #expect(rig.editorState.contentGeneration == generation)
        #expect(rig.editorState.contentState == .idle)
    }

    @Test("TransBarrier waits for a write reserved earlier; on its bound the hold is ended and nothing else changes")
    func barrierWaitsAndTimesOut() async throws {
        let rig = try TransitionRig(markdown: book)
        let writer = try #require(rig.sync.writer)
        let earlier = writer.reserve() // an earlier queued write that has not applied
        let outcome = await rig.sync.beginTransition(barrierTimeout: 0.3)
        #expect(outcome == .barrierTimedOut(token: 7))
        #expect(rig.calls("endTransition(7)").count == 1)
        earlier.settleIfOpen(.empty)
        // Settled in time: the barrier opens.
        let blocker = writer.reserve()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            blocker.settleIfOpen(.empty)
        }
        #expect(await rig.sync.beginTransition(barrierTimeout: 5) == .ready(token: 7))
    }

    @Test("a begin the page cannot answer holds nothing: today's path, and any hold is ended with a null token")
    func beginFailureFallsBack() async throws {
        let rig = try TransitionRig(markdown: book)
        rig.beginAnswer = nil
        let start = await rig.editorState.beginZoomTransition(rig.sync, label: "test")
        #expect(start == .legacy)
        #expect(rig.calls("endTransition(null)").count == 1)
        // The ticket was settled: the queue is not stuck behind it.
        let writer = try #require(rig.sync.writer)
        #expect(await writer.awaitSettled(through: writer.nextSequence - 1, timeout: 1) == .settled)
        // A page that refuses (a Cmd-Z latched) also holds nothing.
        rig.beginAnswer = #"{"ok":false,"reason":"pressLatched"}"#
        #expect(await rig.editorState.beginZoomTransition(rig.sync, label: "test") == .legacy)
    }

    @Test("zoom out carried: the rows' whole document is swapped in after the barrier, the zoom is cleared, the state is .idle")
    func zoomOutSwapsTheWholeDocument() async throws {
        let rig = try TransitionRig(markdown: book)
        let two = try rig.block(startingWith: "# Chapter Two")
        rig.editorState.zoomedSectionId = two.id
        rig.editorState.zoomedSectionIds = [two.id]
        rig.editorState.zoomedBlockRange = (start: two.sortOrder, end: nil)
        let generation = rig.editorState.contentGeneration
        rig.swapAnswer = #"{"ok":true,"replayed":2,"dropped":0,"outside":{"updates":[],"inserts":[],"deletes":[]}}"#
        let handled = await rig.editorState.zoomOutCarried(restoreScrollToSectionId: two.id)
        #expect(handled)
        let swap = try #require(rig.calls("swapTransition").first)
        #expect(swap.contains("Chapter One") && swap.contains("Chapter Two"))
        #expect(swap.contains(#""zoomMode":false"#))
        #expect(rig.stateAtSwap == .zoomTransition)
        #expect(rig.generationAtSwap == generation + 1)
        #expect(rig.editorState.zoomedSectionId == nil)
        #expect(rig.editorState.zoomedBlockRange == nil)
        #expect(rig.editorState.contentState == .idle)
        #expect(rig.editorState.content.contains("Chapter One"))
        #expect(rig.oldWayPushes.isEmpty)
    }

    @Test("zoom in carried: the zoomed chapter is swapped in, and typing outside the range is written after .idle")
    func zoomInWritesTheOutsideBatchAfterIdle() async throws {
        let rig = try TransitionRig(markdown: book)
        let two = try rig.block(startingWith: "# Chapter Two")
        let first = try rig.block(startingWith: "First paragraph")
        rig.swapAnswer = #"{"ok":true,"replayed":0,"dropped":1,"outside":"# + rig.updateJSON(first.id, "First paragraph. outside") + "}"
        let handled = await rig.editorState.zoomToSectionCarried(two.id, mode: .full)
        #expect(handled)
        let swap = try #require(rig.calls("swapTransition").first)
        #expect(swap.contains("Chapter Two") && !swap.contains("Chapter One"))
        #expect(swap.contains(#""zoomMode":true"#))
        #expect(rig.editorState.zoomedSectionId == two.id)
        #expect(rig.editorState.contentState == .idle)
        // The outside batch went through the queue after the swap.
        let writer = try #require(rig.sync.writer)
        #expect(await writer.awaitSettled(through: writer.nextSequence - 1, timeout: 2) == .settled)
        #expect(try rig.block(startingWith: "First paragraph").markdownFragment == "First paragraph. outside")
    }

    @Test("a refused swap: the held typing is written, then the rows are pushed the old way (the catch-up)")
    func refusedSwapCatchesUp() async throws {
        let rig = try TransitionRig(markdown: book)
        let two = try rig.block(startingWith: "# Chapter Two")
        let second = try rig.block(startingWith: "Second paragraph")
        rig.swapAnswer = #"{"ok":false,"refused":true,"reason":"unplaceable","batch":"#
            + rig.updateJSON(second.id, "Second paragraph. held") + "}"
        let handled = await rig.editorState.zoomToSectionCarried(two.id, mode: .full)
        #expect(handled)
        #expect(rig.oldWayPushes.count == 1)
        #expect(rig.oldWayPushes.first?.contains("Second paragraph. held") == true)
        #expect(rig.editorState.zoomedSectionId == two.id)
        #expect(rig.editorState.contentState == .idle)
    }

    @Test("user zooms take the carried path in both editors (job A8); with no block sync they take today's path")
    func legacySwitchIsHonoured() async throws {
        let rig = try TransitionRig(markdown: book)
        #expect(rig.editorState.usesCarriedZoom) // no UI-test environment in a unit test
        rig.editorState.editorMode = .source
        #expect(rig.editorState.usesCarriedZoom) // Phase 5 job A8: Markdown is carried too
        rig.editorState.blockSyncService = nil
        #expect(!rig.editorState.usesCarriedZoom) // no configured editor: today's path
    }
}

@Suite("Phase 5 A7: commands pressed during a transition are held")
@MainActor
struct TransitionHoldTests {

    @Test("Cmd-/ during a zoom is held, then asked again from the top when the zoom is over")
    func cmdSlashDuringZoomIsHeld() async throws {
        let state = EditorViewState()
        state.transitionHolds.zoomRunning = true
        let asked = TransitionNotificationCounter(name: .willToggleEditorMode)
        state.requestEditorModeToggle()
        #expect(state.heldModeToggleTask != nil)
        #expect(asked.count == 0)
        try await Task.sleep(for: .milliseconds(150))
        #expect(asked.count == 0)
        state.transitionHolds.zoomRunning = false
        try await Task.sleep(for: .milliseconds(400))
        #expect(asked.count == 1)
        #expect(state.heldModeToggleTask == nil)
    }

    @Test("Cmd-/ during .zoomTransition is held too (it used to be refused)")
    func cmdSlashDuringZoomTransitionIsHeld() async throws {
        let state = EditorViewState()
        state.contentState = .zoomTransition
        state.requestEditorModeToggle()
        #expect(state.heldModeToggleTask != nil)
        state.contentState = .idle
        try await Task.sleep(for: .milliseconds(400))
        #expect(state.heldModeToggleTask == nil)
    }

    @Test("a zoom pressed during a switch runs when the switch is over; the newest press replaces an older one")
    func zoomDuringSwitchIsHeldAndTheLastWishWins() async throws {
        let state = EditorViewState()
        state.contentState = .editorTransition
        #expect(state.zoomMustWaitForTransition)
        var ran: [String] = []
        state.holdZoomUntilTransitionEnds { ran.append("first") }
        state.holdZoomUntilTransitionEnds { ran.append("second") }
        try await Task.sleep(for: .milliseconds(150))
        #expect(ran.isEmpty)
        state.contentState = .idle
        try await Task.sleep(for: .milliseconds(200))
        #expect(ran == ["second"])
        #expect(state.transitionHolds.heldZoomTask == nil)
    }

    @Test("a held zoom is dropped with the project when a close begins")
    func heldZoomDroppedOnClose() async throws {
        let state = EditorViewState()
        state.contentState = .editorTransition
        var ran = false
        state.holdZoomUntilTransitionEnds { ran = true }
        state.structuralGate.isClosedToNewWork = true
        state.contentState = .idle
        try await Task.sleep(for: .milliseconds(200))
        #expect(!ran)
        #expect(state.transitionHolds.heldZoomTask == nil)
    }
}

/// Counts posts of one notification while it lives.
@MainActor
final class TransitionNotificationCounter {
    private(set) var count = 0
    private var token: NSObjectProtocol?

    init(name: Notification.Name) {
        token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.count += 1 }
        }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}
