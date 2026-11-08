//
//  MarkdownPageReadinessTests.swift
//  final finalTests
//
//  Tier 1 (t-633df056, Phase 5 job A5): the Markdown page's readiness record on `EditorViewState` and the bounded wait a Markdown section
//  command makes for it (EditorViewState+MarkdownPageReadiness.swift), and the controller's shared precondition that calls it
//  (StructuralUndoController+MarkdownPageWait.swift). No UI: the record is driven by the same calls the switch and the CodeMirror
//  `onWebViewReady` closure make (`toggleEditorMode()`, `markMarkdownPageReady()`).
//

import Foundation
import Testing
@testable import final_final

@MainActor
struct MarkdownPageReadinessTests {

    /// A state whose mode has just been switched to Markdown the way the app does it (the page is now loading).
    private func switchedToMarkdown() -> EditorViewState {
        let state = EditorViewState()
        #expect(state.editorMode == .wysiwyg)
        #expect(!state.markdownPageLoading, "a fresh state is not loading a page")
        state.toggleEditorMode()
        #expect(state.editorMode == .source)
        return state
    }

    @Test("The switch to Markdown starts the load; the page's onWebViewReady ends it")
    func recordFollowsTheSwitchAndThePage() {
        let state = switchedToMarkdown()
        #expect(state.markdownPageLoading, "the badge says Markdown but the page is not there yet")
        state.markMarkdownPageReady()
        #expect(!state.markdownPageLoading)
        state.toggleEditorMode()   // back to Rich Text
        #expect(!state.markdownPageLoading, "leaving Markdown leaves nothing to wait for")
    }

    @Test("A plain editorMode assignment (the unit-test rigs) never starts a load, so nothing waits in them")
    func plainAssignmentDoesNotStartALoad() async {
        let state = EditorViewState()
        state.editorMode = .source
        #expect(!state.markdownPageLoading)
        #expect(await state.awaitMarkdownPage(timeout: .seconds(5)) == .ready)
    }

    @Test("Ready first: a command that arrives once the page is ready does not wait")
    func readyFirst() async {
        let state = switchedToMarkdown()
        state.markMarkdownPageReady()
        let began = ContinuousClock.now
        #expect(await state.awaitMarkdownPage(timeout: .seconds(5)) == .ready)
        #expect(ContinuousClock.now - began < .seconds(1), "no wait: the page was already there")
        #expect(state.markdownPageWaiters.isEmpty)
    }

    @Test("Ready later: a command that arrives before the page waits for it and goes on the moment it is ready")
    func readyLater() async {
        let state = switchedToMarkdown()
        let waiter = Task { @MainActor in await state.awaitMarkdownPage(timeout: .seconds(10)) }
        let parked = await gateWaitUntil { state.markdownPageWaiters.count == 1 }
        #expect(parked, "the command is parked on the record while the page loads")
        state.markMarkdownPageReady()
        #expect(await waiter.value == .ready)
        #expect(state.markdownPageWaiters.isEmpty, "the waiter is forgotten once resumed")
        #expect(!state.markdownPageLoading)
    }

    @Test("Several commands waiting for the same page all go on when it is ready")
    func severalWaitersResume() async {
        let state = switchedToMarkdown()
        let first = Task { @MainActor in await state.awaitMarkdownPage(timeout: .seconds(10)) }
        let second = Task { @MainActor in await state.awaitMarkdownPage(timeout: .seconds(10)) }
        let parked = await gateWaitUntil { state.markdownPageWaiters.count == 2 }
        #expect(parked)
        state.markMarkdownPageReady()
        #expect(await first.value == .ready)
        #expect(await second.value == .ready)
        #expect(state.markdownPageWaiters.isEmpty)
    }

    @Test("Timeout: a page that never comes ends the wait as timed out, and the record stays as it was")
    func timeout() async {
        let state = switchedToMarkdown()
        let began = ContinuousClock.now
        #expect(await state.awaitMarkdownPage(timeout: .milliseconds(80)) == .timedOut)
        #expect(ContinuousClock.now - began >= .milliseconds(80), "the whole bound was waited")
        #expect(state.markdownPageLoading, "a timeout does not pretend the page is there")
        #expect(state.markdownPageWaiters.isEmpty, "the timed-out waiter is forgotten")
    }

    @Test("Mode change: leaving Markdown while a command waits ends the wait as a mode change")
    func modeChange() async {
        let state = switchedToMarkdown()
        let waiter = Task { @MainActor in await state.awaitMarkdownPage(timeout: .seconds(10)) }
        let parked = await gateWaitUntil { state.markdownPageWaiters.count == 1 }
        #expect(parked)
        state.toggleEditorMode()   // back to Rich Text
        #expect(await waiter.value == .modeChanged)
        #expect(!state.markdownPageLoading)
        #expect(state.markdownPageWaiters.isEmpty)
    }

    @Test("Not in Markdown: there is no page to wait for")
    func notInMarkdown() async {
        let state = EditorViewState()
        #expect(await state.awaitMarkdownPage(timeout: .seconds(5)) == .modeChanged)
    }

    @Test("A late ready after a timeout resumes nothing and clears the record")
    func lateReadyAfterTimeout() async {
        let state = switchedToMarkdown()
        #expect(await state.awaitMarkdownPage(timeout: .milliseconds(50)) == .timedOut)
        state.markMarkdownPageReady()
        #expect(!state.markdownPageLoading)
        #expect(await state.awaitMarkdownPage(timeout: .seconds(5)) == .ready, "the next command does not wait")
    }

    // MARK: - The controller's shared precondition

    @Test("The precondition lets a press go on at once when no page load is under way (Markdown or not)")
    func preconditionWithNoLoad() async {
        let rig = GateRig()
        #expect(await rig.controller.awaitMarkdownPageForStructuralCommand(label: "test", timeout: .seconds(5)), "Rich Text: nothing to wait for")
        rig.editorState.toggleEditorMode()
        rig.editorState.markMarkdownPageReady()
        #expect(await rig.controller.awaitMarkdownPageForStructuralCommand(label: "test", timeout: .seconds(5)), "Markdown, page ready")
    }

    @Test("The precondition holds a press until the page is ready, then lets it go on")
    func preconditionHoldsThenGoesOn() async {
        let rig = GateRig()
        rig.editorState.toggleEditorMode()
        let press = Task { @MainActor in await rig.controller.awaitMarkdownPageForStructuralCommand(label: "test", timeout: .seconds(10)) }
        let parked = await gateWaitUntil { rig.editorState.markdownPageWaiters.count == 1 }
        #expect(parked, "the press waits on the record")
        rig.editorState.markMarkdownPageReady()
        #expect(await press.value, "the press goes on once the page is ready")
    }

    @Test("The precondition gives a press to the old route when the wait times out or the editor leaves Markdown")
    func preconditionFallsBack() async {
        let rig = GateRig()
        rig.editorState.toggleEditorMode()
        #expect(await rig.controller.awaitMarkdownPageForStructuralCommand(label: "test", timeout: .milliseconds(50)) == false, "timed out")
        let press = Task { @MainActor in await rig.controller.awaitMarkdownPageForStructuralCommand(label: "test", timeout: .seconds(10)) }
        let parked = await gateWaitUntil { rig.editorState.markdownPageWaiters.count == 1 }
        #expect(parked)
        rig.editorState.toggleEditorMode()   // back to Rich Text while the press waits
        #expect(await press.value == false, "the editor left Markdown: the old route")
    }
}
