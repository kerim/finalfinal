//
//  EditorFirstSwitchCaretTests.swift
//  final finalTests
//
//  Tier 2 (t-94369a83 Phase 4b slice 2a, fix round 9): the VM test `testDeleteThenSwitchToMarkdownAndType_book12`. Delete a chapter,
//  press the Rich Text / Markdown switch at once and type: the typed sentence landed as a new paragraph at the very start of the
//  document, not at the caret (UX contract section 2: the switch never loses the caret).
//
//  The mechanism: the switch is two phases. Phase one asks the editor to save its caret, and the reply stores it in
//  `cursorPositionToRestore`. Phase two (`handleEditorModeToggle`) then waited for the delete's job and its follow-up work. The
//  follow-up work starts the Notes and Bibliography rebuilds, and each of those clears `cursorPositionToRestore` (a position computed
//  before a rebuild is stale), so the Markdown editor opened with no caret, at line 1 column 0.
//
//  The fix: the press is held BEFORE the caret is saved while a delete's job or follow-up work is unfinished
//  (`EditorViewState.requestEditorModeToggle`), so the caret is saved after the rebuilds and nothing clears it afterwards.
//
//  The ContentView observers are not mounted in a unit test, so the tests play them: a stand-in rebuild clears the caret the way
//  `handleNotesSectionChanged` does, and the editor's reply to the cursor-save request is sent by hand through the real
//  `handleDidSaveCursorPosition` and `handleEditorModeToggle`.
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import SwiftUI
import Testing
@testable import final_final

/// Stands for `ContentView.cursorPositionToRestore`.
@MainActor
private final class CaretBox {
    var value: CursorPosition?
}

@Suite("The switch keeps the caret after a delete — Phase 4b slice 2a fix round 9 (Tier 2)", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct EditorFirstSwitchCaretTests {

    private static let sectionTitle = "1.2 The Village Registers"

    @Test("Round 9: a switch pressed while a delete's follow-up work is unfinished saves the caret after that work, and the Markdown editor gets it")
    func testSwitchAfterDeleteSavesTheCaretAfterTheFollowUp_article() async throws {
        let rig = try EditorFirstRig(markdown: ComplexDocumentFixture.article.editorMarkdown, configureSyncServices: false)
        let root = try rig.heading(Self.sectionTitle)
        try rig.setReply(.init(removedLeaderIds: [root.id]))
        let box = CaretBox()
        let seen = GateOrderLog()
        let willObserver = NotificationCenter.default.addObserver(forName: .willToggleEditorMode, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { seen.note("cursor save requested") }
        }
        defer { NotificationCenter.default.removeObserver(willObserver) }

        // The delete's follow-up work is held at its start. When it goes on it starts a rebuild that clears the caret, as the Notes
        // rebuild the real follow-up starts does.
        let followUpMayGoOn = LifecycleEntryHarness.Gate()
        defer { followUpMayGoOn.open() }
        rig.controller.testEFSettleHold = { [weak rig] in
            guard let rig else { return }
            seen.note("follow-up held")
            await followUpMayGoOn.wait()
            _ = try? rig.syncEditorContentFromDatabase()
            let rebuild = Task { @MainActor in
                box.value = nil
                seen.note("rebuild cleared the caret")
            }
            rig.editorState.registerRebuildTask(rebuild)
        }
        let outcome = await rig.controller.performSectionDelete(rootId: root.id)
        #expect(outcome == .performed)
        let held = await gateWaitUntil({ seen.items.contains("follow-up held") }, iterations: 4000)
        #expect(held, "the delete's follow-up work must have started: \(seen.items)")
        #expect(rig.editorState.efJobRegistry.hasUnsettledWork, "precondition: the delete is not settled")
        #expect(rig.editorState.structuralGate.isIdle, "precondition: no structural command holds the gate, only the delete's work is pending")

        // The user presses the switch at once.
        rig.editorState.requestEditorModeToggle()
        #expect(rig.editorState.heldModeToggleTask != nil, "the press is held, not started")
        try await Task.sleep(for: .milliseconds(200))
        #expect(
            !seen.items.contains("cursor save requested"),
            "the caret must not be saved while the delete's follow-up work is unfinished (its rebuild would clear it): \(seen.items)")
        #expect(rig.editorState.editorMode == .wysiwyg)

        // The follow-up work goes on, its rebuild clears the caret, it ends, and only then is the caret saved.
        followUpMayGoOn.open()
        let requested = await gateWaitUntil({ seen.items.contains("cursor save requested") }, iterations: 4000)
        #expect(requested, "the held press asks the editor to save the caret once the delete is settled: \(seen.items)")
        let clearedAt = try #require(seen.items.firstIndex(of: "rebuild cleared the caret"), "the rebuild ran: \(seen.items)")
        let savedAt = try #require(seen.items.firstIndex(of: "cursor save requested"))
        #expect(clearedAt < savedAt, "the caret is saved AFTER the rebuild cleared it: \(seen.items)")
        #expect(!rig.editorState.efJobRegistry.hasUnsettledWork, "and the delete is settled by then")
        let released = await gateWaitUntil { rig.editorState.heldModeToggleTask == nil }
        #expect(released)

        // The editor answers the request with the caret; nothing is pending, so the real handler switches at once.
        let caret = CursorPosition(line: 42, column: 7)
        let reply = Notification(name: .didSaveCursorPosition, object: nil, userInfo: ["position": caret])
        let binding = Binding<CursorPosition?>(get: { box.value }, set: { box.value = $0 })
        Color.clear.handleDidSaveCursorPosition(reply, editorState: rig.editorState, cursorRestore: binding)
        Color.clear.handleEditorModeToggle(
            editorState: rig.editorState, sectionSyncService: SectionSyncService(),
            findBarState: FindBarState(), unifiedUndoService: rig.unifiedUndo)
        let switched = await gateWaitUntil({ rig.editorState.editorMode == .source }, iterations: 4000)
        #expect(switched, "the switch to Markdown happened")
        let received = box.value
        #expect(received == caret, "the Markdown editor gets the caret the user had, not nil (line 1): \(String(describing: received))")
        #expect(
            seen.items.filter { $0 == "cursor save requested" }.count == 1,
            "the caret is saved once: \(seen.items)")
    }

    @Test("Round 9: a switch held for a delete's unfinished work is dropped, not run, when a close starts before that work ends")
    func testSwitchHeldForDeleteWorkIsDroppedWhenACloseStarts() async throws {
        let rig = try EditorFirstRig(markdown: "# First Chapter\n\nBody one.\n\n## Second Section\n\nBody two.")
        rig.js.answer("flushPendingBlockChanges", true)
        rig.js.answer("hasBlockChanges", false)
        rig.fetchAnswerProvider = { [weak rig] in try? rig?.assembledMarkdown() }
        let seen = GateOrderLog()
        let willObserver = NotificationCenter.default.addObserver(forName: .willToggleEditorMode, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { seen.note("cursor save requested") }
        }
        defer { NotificationCenter.default.removeObserver(willObserver) }
        let registry = rig.editorState.efJobRegistry
        let opId = UUID()
        registry.register(opId)   // a delete whose job has not ended

        rig.editorState.requestEditorModeToggle()
        #expect(rig.editorState.heldModeToggleTask != nil, "the press is held for the delete's work")
        let gate = rig.editorState.structuralGate
        let close = Task { @MainActor in await rig.runLifecycle(.close, bounds: .production) }
        let armed = await gateWaitUntil { gate.isClosedToNewWork }
        #expect(armed, "the close must have placed its barrier while the press waits")

        registry.resolve(opId, .applied)
        registry.markSettled(opId)
        let result = await close.value
        try await Task.sleep(for: .milliseconds(150))

        #expect(result.outcome == .flushed, "the close completed: \(result.outcome)")
        #expect(seen.items.isEmpty, "the held switch must not start beside the close's save: \(seen.items)")
        #expect(rig.editorState.heldModeToggleTask == nil, "and it is gone")
        #expect(rig.editorState.editorMode == .wysiwyg)
    }
}
