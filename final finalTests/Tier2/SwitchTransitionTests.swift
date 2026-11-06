//
//  SwitchTransitionTests.swift
//  final finalTests
//
//  Phase 5 jobs A9 and A10 (design: docs/architecture/write-queue-plan/phase5/a7-a10-design.md, sections 3 and 4; run record
//  docs/architecture/write-queue-plan/phase5/a9-notes.md): the Swift pieces of the carried switch between Rich Text and Markdown that run
//  without a live page:
//    - TransSwap's drain: `takeTransitionBatch` reads the held typing WITHOUT ending the hold, and the batch goes through the queue
//      (`writeTransitionBatch` + `awaitTransitionBarrier`) into the rows the carry is assembled from;
//    - the Markdown text the incoming page is given (`markdownSwitchText`): every section anchor right before its own heading, the
//      bibliography marker in, and the text round-trips to the Rich Text text (so `S0 -> S1` differs only by the carried typing);
//    - the holds: a zoom pressed during a carried switch waits (`switchRunning`); a zoomed switch keeps today's path;
//    - the handover: a staged page is claimed once, and a `FocusOnAttachWebView` takes keyboard focus when it is attached to a window.
//  The page calls themselves are covered by the web tests (web/codemirror/src/__tests__/switch-carry.test.ts,
//  web/milkdown/src/__tests__/switch-take.test.ts); the whole switch by the real-app tests.
//

import AppKit
import Foundation
import Testing
import WebKit
@testable import final_final

private let book = """
# Chapter One

First paragraph.

# Chapter Two

Second paragraph.
"""

@Suite("Phase 5 A9/A10: the carried switch's Swift side")
@MainActor
struct SwitchTransitionTests {

    @Test("TransSwap's drain: the take keeps the hold, and its batch reaches the rows through the queue")
    func takeKeepsTheHoldAndTheBatchReachesTheRows() async throws {
        let rig = try TransitionRig(markdown: book)
        let start = await rig.editorState.beginZoomTransition(rig.sync, label: "switch test")
        guard case .ready(let token) = start else {
            Issue.record("the begin did not start: \(start)")
            return
        }
        let second = try rig.block(startingWith: "Second paragraph")
        let batch = rig.updateJSON(second.id, "Second paragraph. typed in the outgoing page")
        var scripts: [String] = []
        rig.sync.testJSEvaluator = { script in
            scripts.append(script)
            if script.contains("takeTransitionBatch") { return #"{"ok":true,"batch":"# + batch + #","cursor":{"line":7,"column":44}}"# }
            if script.contains("confirmBlockIds") { return true }
            return nil
        }
        guard let taken = await rig.sync.takeTransitionBatch(token: token, from: rig.view) else {
            Issue.record("the take was not read")
            return
        }
        #expect(taken.cursor == CursorPosition(line: 7, column: 44))
        #expect(!scripts.contains { $0.contains("endTransition") }, "the take does not end the hold")
        guard let seq = rig.sync.writeTransitionBatch(taken.batch) else {
            Issue.record("the batch got no writer turn")
            return
        }
        #expect(await rig.sync.awaitTransitionBarrier(through: seq, timeout: 5))
        #expect(try rig.block(startingWith: "Second paragraph").markdownFragment == "Second paragraph. typed in the outgoing page")
    }

    @Test("A stale or refused take reads as nothing to carry (the caller falls back), never as an empty success")
    func refusedTakeIsNil() async throws {
        let rig = try TransitionRig(markdown: book)
        rig.sync.testJSEvaluator = { _ in #"{"ok":false,"reason":"staleToken"}"# }
        #expect(await rig.sync.takeTransitionBatch(token: 9, from: rig.view) == nil)
    }

    @Test("The Markdown text from the rows: every anchor right before its heading, and the text round-trips to the Rich Text text")
    func markdownSwitchTextAnchorsEachHeading() throws {
        for document in [ComplexDocumentFixture.article, ComplexDocumentFixture.book6] {
            let inputs = ComplexDocumentFixture.switchInputs(for: document)
            let service = SectionSyncService()
            let text = EditorViewState.markdownSwitchText(
                rows: inputs.storedBlocks, sections: inputs.sectionsToInject, sectionSync: service)
            let (cleaned, anchors) = service.extractSectionAnchors(markdown: text)
            #expect(SectionSyncService.stripBibliographyMarker(from: cleaned) == inputs.content)
            #expect(anchors.count == inputs.sectionsToInject.count)
            let byId = Dictionary(uniqueKeysWithValues: inputs.storedBlocks.map { ($0.id, $0) })
            for section in inputs.sectionsToInject {
                guard let heading = byId[section.id], let firstLine = heading.markdownFragment.split(separator: "\n").first else { continue }
                #expect(text.contains("<!-- @sid:\(section.id) -->" + firstLine),
                        "the anchor of \(section.id) sits right before its heading")
            }
        }
    }

    @Test("A zoom pressed during a carried switch is held; the content-state watchdog's exemption follows the same flag")
    func zoomWaitsForARunningSwitch() throws {
        let rig = try TransitionRig(markdown: book)
        #expect(!rig.editorState.zoomMustWaitForTransition)
        rig.editorState.transitionHolds.switchRunning = true
        #expect(rig.editorState.zoomMustWaitForTransition)
        rig.editorState.transitionHolds.switchRunning = false
    }

    @Test("A zoomed switch keeps today's path; an unzoomed one with a page takes the carried one")
    func zoomedSwitchIsLegacy() throws {
        let rig = try TransitionRig(markdown: book)
        rig.editorState.editorMode = .wysiwyg
        #expect(rig.editorState.usesCarriedSwitch)
        rig.editorState.zoomedSectionIds = [try rig.block(startingWith: "# Chapter Two").id]
        #expect(!rig.editorState.usesCarriedSwitch)
    }

    @Test("The handover: a staged page is claimed once; it takes keyboard focus when attached")
    func stagedPageIsClaimedOnceAndFocusedOnAttach() throws {
        let page = FocusOnAttachWebView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        EditorPreloader.shared.stageCodeMirrorPage(page, content: "text")
        #expect(page.focusOnAttach)
        #expect(EditorPreloader.shared.claimStagedCodeMirrorPage()?.webView === page)
        #expect(EditorPreloader.shared.claimStagedCodeMirrorPage() == nil)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView?.addSubview(page)
        #expect(window.firstResponder === page)
        #expect(!page.focusOnAttach, "the focus is asked for once")
        page.removeFromSuperview()
    }

    /// Hand test 2026-11-06 (a9-notes.md, "Cursor fix and switch notice"): the old editor stays on screen until the new one has its text,
    /// so a switch that takes over a second shows "Switching to Markdown…" / "Switching to Rich Text…", and takes it down when it ends.
    @Test("A switch that takes over the delay shows 'Switching to …' and takes it down when it ends; a quick one shows nothing")
    func switchNoticeShowsAfterTheDelayAndIsDismissedOnEveryExit() async {
        let savedDelay = DelayedProgressToast.defaultDelay
        DelayedProgressToast.defaultDelay = .milliseconds(30)
        defer { DelayedProgressToast.defaultDelay = savedDelay }
        for toMarkdown in [true, false] {
            let state = EditorViewState()
            let toasts = ToastCenter()
            state.toastCenter = toasts
            state.editorMode = toMarkdown ? .wysiwyg : .source
            let wanted = toMarkdown ? DelayedProgressToast.switchingToMarkdownMessage : DelayedProgressToast.switchingToRichTextMessage
            // Slow: the switch waits behind a held gate, past the delay. It then ends through today's switch (no page here).
            var fellBack = false
            #expect(await state.structuralGate.acquire() == .granted)
            start(state, toMarkdown: toMarkdown) { fellBack = true }
            let shown = await gateWaitUntil { toasts.current?.message == wanted }
            #expect(shown, "a switch that takes over the delay shows \(wanted)")
            #expect(toasts.current?.style == .progress)
            state.structuralGate.release()
            #expect(await gateWaitUntil { !state.transitionHolds.switchRunning })
            #expect(fellBack, "with no page the switch ends through today's switch")
            #expect(toasts.current == nil, "the notice is taken down when the switch ends")
            // Quick: the same fall-back, at once: nothing shows, not even after the delay.
            start(state, toMarkdown: toMarkdown) {}
            #expect(await gateWaitUntil { !state.transitionHolds.switchRunning })
            try? await Task.sleep(for: .milliseconds(80))
            #expect(toasts.current == nil, "a switch that ends within the delay shows nothing")
            // Refused: a close started while the switch waited for the gate.
            #expect(await state.structuralGate.acquire() == .granted)
            start(state, toMarkdown: toMarkdown) {}
            #expect(await gateWaitUntil { toasts.current?.message == wanted })
            _ = state.structuralGate.cancelWaiters()
            #expect(await gateWaitUntil { !state.transitionHolds.switchRunning })
            #expect(toasts.current == nil, "a switch refused by a close takes its notice down")
            state.structuralGate.release()
        }
    }

    private func start(_ state: EditorViewState, toMarkdown: Bool, legacy: @escaping @MainActor () -> Void) {
        if toMarkdown {
            state.startCarriedSwitchToMarkdown(sectionSync: SectionSyncService(), cursor: nil, legacy: legacy)
        } else {
            state.startCarriedSwitchToRichText(sectionSync: SectionSyncService(), cursor: nil, legacy: legacy)
        }
    }
}
