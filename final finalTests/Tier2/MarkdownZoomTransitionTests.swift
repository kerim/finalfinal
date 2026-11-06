//
//  MarkdownZoomTransitionTests.swift
//  final finalTests
//
//  Phase 5 job A8 (design: docs/architecture/write-queue-plan/phase5/a7-a10-design.md, section 2): the Swift side of the carried zoom in
//  Markdown and the queued zoomed write, with a REAL `BlockSyncService`, `DocumentWriter` and `MarkdownBlockWriter` (A7's `TransitionRig`,
//  in Markdown mode) and the CodeMirror page's answers scripted through `transitionHolds.testMarkdownPage`. What these pin:
//    - the zoomed re-parse is a queue turn: it waits behind a write reserved earlier, and a turn whose zoom has moved on writes nothing;
//    - TransBegin + TransLiveRead + TransBarrier: the page's step-1 text is in the rows before the state leaves `.idle` (F8);
//    - TransPushFrom + TransReplay: the zoom out swaps the full text in (anchors and all) and clears the zoom; the zoom in swaps the chapter
//      in and writes the outside typing through the per-block writer after `.idle`;
//    - a refused swap runs today's zoom (the catch-up); a begin the page cannot answer hands the zoom back to today's path;
//    - the one-shot skip of the swapped text in the content observer.
//

import Foundation
import GRDB
import Testing
@testable import final_final

private let book = """
# Chapter One

First paragraph.

# Chapter Two

Second paragraph.

# Chapter Three

Third paragraph.
"""

/// A scripted CodeMirror page: what `beginTransition()` and `swapTransition` answer, and what Swift asked.
@MainActor
private final class ScriptedMarkdownPage {
    var scripts: [String] = []
    var beginRaw: String?
    var beginAnswer: String?
    var swapAnswer: String?
    /// Run when the swap is asked (reads the rows and the state at that moment).
    var onSwap: (() -> Void)?

    func answer(_ script: String) -> String? {
        scripts.append(script)
        if script.contains("beginTransition") {
            if let beginAnswer { return beginAnswer }
            guard let beginRaw else { return nil }
            return Self.json(["ok": true, "token": 5, "raw": beginRaw])
        }
        if script.contains("swapTransition") {
            onSwap?()
            return swapAnswer
        }
        if script.contains("endTransition") { return #"{"ended":true}"# }
        return nil
    }

    func calls(_ name: String) -> [String] { scripts.filter { $0.contains(name) } }

    static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

@MainActor
private func markdownRig(_ page: ScriptedMarkdownPage) throws -> TransitionRig {
    let rig = try TransitionRig(markdown: book)
    rig.editorState.editorMode = .source
    rig.editorState.transitionHolds.testMarkdownPage = { script in page.answer(script) }
    return rig
}

@MainActor
private func zoomInto(_ rig: TransitionRig, _ heading: String) throws -> Block {
    let root = try rig.block(startingWith: heading)
    let target = try #require(try rig.editorState.buildZoomInTarget(sectionId: root.id, mode: .full, db: rig.db, pid: rig.pid))
    rig.editorState.zoomedSectionId = root.id
    rig.editorState.zoomedSectionIds = target.descendantIds
    rig.editorState.zoomedBlockRange = target.range
    return root
}

@Suite("Phase 5 A8: the queued zoomed write and the carried Markdown zoom")
@MainActor
struct MarkdownZoomTransitionTests {

    @Test("the zoomed write is a queue turn: it waits behind an earlier reserved write, then writes the range")
    func zoomedWriteWaitsForItsTurn() async throws {
        let rig = try markdownRig(ScriptedMarkdownPage())
        _ = try zoomInto(rig, "# Chapter Two")
        let writer = try #require(rig.sync.writer)
        let earlier = writer.reserve()
        let editorState = rig.editorState
        let write = Task { @MainActor in
            await editorState.markdownWriter.writeZoomedNow(
                overrideContent: "# Chapter Two\n\nSecond paragraph. zoomed typing", editorState: editorState,
                guardsHold: { true }, refire: {})
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(try rig.block(startingWith: "Second paragraph").markdownFragment == "Second paragraph.")
        #expect(editorState.markdownWriter.inFlight != nil) // published: a debounce fire waits for it
        earlier.settleIfOpen(.empty)
        #expect(await write.value == .proceeded)
        #expect(try rig.block(startingWith: "Second paragraph").markdownFragment == "Second paragraph. zoomed typing")
        // Only the range was written: the other chapters are untouched.
        #expect(try rig.block(startingWith: "Third paragraph").markdownFragment == "Third paragraph.")
        #expect(editorState.markdownWriter.inFlight == nil)
        #expect(await writer.awaitSettled(through: writer.nextSequence - 1, timeout: 1) == .settled)
    }

    @Test("a zoomed write whose zoom moved on before its turn writes nothing (no text lands in another range)")
    func zoomedWriteDroppedWhenTheZoomMovedOn() async throws {
        let rig = try markdownRig(ScriptedMarkdownPage())
        _ = try zoomInto(rig, "# Chapter Two")
        let writer = try #require(rig.sync.writer)
        let earlier = writer.reserve()
        let editorState = rig.editorState
        let write = Task { @MainActor in
            await editorState.markdownWriter.writeZoomedNow(
                overrideContent: "# Chapter Two\n\nSecond paragraph. stale", editorState: editorState,
                guardsHold: { true }, refire: {})
        }
        try await Task.sleep(for: .milliseconds(100))
        editorState.zoomEpoch += 1 // a zoom out or a re-zoom began
        earlier.settleIfOpen(.empty)
        #expect(await write.value == .abandoned)
        #expect(try rig.block(startingWith: "Second paragraph").markdownFragment == "Second paragraph.")
    }

    @Test("TransBegin + TransBarrier: the page's step-1 text is in the rows before the state leaves .idle (F8)")
    func beginTextIsWrittenBeforeTheGenerationMoves() async throws {
        let page = ScriptedMarkdownPage()
        page.beginRaw = book.replacingOccurrences(of: "First paragraph.", with: "First paragraph. typed")
        let rig = try markdownRig(page)
        let generation = rig.editorState.contentGeneration
        let start = await rig.editorState.beginMarkdownZoomTransition(label: "test")
        #expect(start == .ready(token: 5))
        #expect(try rig.block(startingWith: "First paragraph").markdownFragment == "First paragraph. typed")
        #expect(rig.editorState.contentGeneration == generation)
        #expect(rig.editorState.contentState == .idle)
    }

    @Test("a begin the page cannot answer holds nothing: today's path, and any hold is ended with a null token")
    func beginFailureFallsBack() async throws {
        let page = ScriptedMarkdownPage()
        let rig = try markdownRig(page)
        #expect(await rig.editorState.zoomToSectionCarried(try rig.block(startingWith: "# Chapter Two").id, mode: .full) == false)
        #expect(page.calls("endTransition(null").count == 1)
        #expect(rig.editorState.zoomedSectionId == nil)
        page.beginAnswer = #"{"ok":false,"reason":"latched"}"#
        #expect(await rig.editorState.beginMarkdownZoomTransition(label: "test") == .legacy)
    }

    @Test("zoom out carried: the full text is swapped in after the barrier, the zoom is cleared, the state is .idle")
    func zoomOutSwapsTheFullText() async throws {
        let page = ScriptedMarkdownPage()
        let rig = try markdownRig(page)
        _ = try zoomInto(rig, "# Chapter Two")
        page.beginRaw = "# Chapter Two\n\nSecond paragraph. typed before"
        var stateAtSwap: EditorContentState?
        var rowAtSwap: String?
        page.onSwap = {
            stateAtSwap = rig.editorState.contentState
            rowAtSwap = try? rig.block(startingWith: "Second paragraph").markdownFragment
        }
        page.swapAnswer = ScriptedMarkdownPage.json(["ok": true, "replayed": 1, "raw": "whole text", "outside": NSNull()])
        #expect(await rig.editorState.zoomOutCarried(restoreScrollToSectionId: nil))
        let swap = try #require(page.calls("swapTransition").first)
        #expect(swap.contains(#""kind":"out""#))
        #expect(swap.contains("Chapter One") && swap.contains("Chapter Three"))
        #expect(stateAtSwap == .zoomTransition)
        #expect(rowAtSwap == "Second paragraph. typed before") // the step-1 text went through the queued zoomed write first
        #expect(rig.editorState.zoomedSectionId == nil)
        #expect(rig.editorState.zoomedBlockRange == nil)
        #expect(rig.editorState.contentState == .idle)
        #expect(rig.oldWayPushes.isEmpty)
    }

    @Test("zoom in carried: the chapter is swapped in, and the outside typing is written through the per-block writer after .idle")
    func zoomInWritesTheOutsideTypingAfterIdle() async throws {
        let page = ScriptedMarkdownPage()
        let rig = try markdownRig(page)
        let two = try rig.block(startingWith: "# Chapter Two")
        page.beginRaw = book
        var stateAtSwap: EditorContentState?
        page.onSwap = { stateAtSwap = rig.editorState.contentState }
        let outside = book.replacingOccurrences(of: "Third paragraph.", with: "Third paragraph. outside")
        page.swapAnswer = ScriptedMarkdownPage.json([
            "ok": true, "replayed": 0, "raw": "# Chapter Two\n\nSecond paragraph.", "outside": outside
        ])
        #expect(await rig.editorState.zoomToSectionCarried(two.id, mode: .full))
        let swap = try #require(page.calls("swapTransition").first)
        #expect(swap.contains(#""kind":"in""#) && swap.contains("Chapter Two") && !swap.contains("Chapter Three"))
        #expect(stateAtSwap == .zoomTransition)
        #expect(rig.editorState.zoomedSectionId == two.id)
        #expect(rig.editorState.zoomedBlockRange != nil)
        #expect(rig.editorState.contentState == .idle)
        if let inFlight = rig.editorState.markdownWriter.inFlight { await inFlight.value }
        #expect(try rig.block(startingWith: "Third paragraph").markdownFragment == "Third paragraph. outside")
        #expect(try rig.block(startingWith: "Second paragraph").markdownFragment == "Second paragraph.")
    }

    @Test("a refused swap runs today's zoom in (the catch-up) and ends .idle and zoomed")
    func refusedSwapCatchesUp() async throws {
        let page = ScriptedMarkdownPage()
        let rig = try markdownRig(page)
        let two = try rig.block(startingWith: "# Chapter Two")
        page.beginRaw = book
        page.swapAnswer = ScriptedMarkdownPage.json(["ok": false, "refused": true, "reason": "straddle", "raw": book])
        #expect(await rig.editorState.zoomToSectionCarried(two.id, mode: .full))
        #expect(rig.editorState.zoomedSectionId == two.id)
        #expect(rig.editorState.contentState == .idle)
    }

    @Test("the content observer skips the swapped text once, and only that text")
    func settledContentIsSkippedOnce() {
        let holds = TransitionHoldState()
        holds.settledContent = "zoomed"
        #expect(holds.consumeSettledContent("zoomed"))
        #expect(!holds.consumeSettledContent("zoomed"))
        holds.settledContent = "zoomed"
        #expect(!holds.consumeSettledContent("typed"))
        #expect(holds.settledContent == nil)
    }

    @Test("Markdown takes the carried zoom")
    func markdownUsesTheCarriedZoom() throws {
        let rig = try markdownRig(ScriptedMarkdownPage())
        #expect(rig.editorState.usesCarriedZoom)
    }
}
