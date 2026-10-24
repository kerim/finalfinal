//
//  MarkdownContentPushDropTests.swift
//  final finalTests
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), slice 1, round 4, O29/O30: the CodeMirror coordinator's two ends of
//  the owed pull, driven on the REAL `CodeMirrorEditor.Coordinator` (no page needed):
//
//   - `handleContentPush` tells `onContentPushDropped` whenever it drops a page `contentChanged` that carries typed text: while a rebuild
//     runs (`isResettingContent` up, which is the guard a rebuild hits first), while the content state is busy, and inside the 150 ms
//     grace after a Swift push. Echoes (text equal to `lastPushedContent`) and accepted pushes tell nothing.
//     BREAK: in `handleContentPush` (CodeMirrorCoordinator+Handlers.swift) delete the `self.onContentPushDropped?()` call of the
//     busy-state guard.    FAILS with: "a dropped contentChanged owed no pull (content state busy)".
//   - `EditorViewState.adoptMarkdownPageText` makes the page's own text the content record SYNCHRONOUSLY and only for its own window:
//     `lastPushedContent`, the source binding and `onContentChange` take it, the 150 ms push grace is not started.
//     BREAK: in `subscribeToMarkdownAdoptNotifications` use `queue: .main` instead of `queue: nil`.
//     FAILS with: "the adoption was not complete when the post returned".
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import SwiftUI
import Testing
@testable import final_final

@Suite("Markdown content-push drops and the page-text adopter — Tier 2 (t-4a8fd8af round 4)", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct MarkdownContentPushDropTests {

    /// Stands for `editorState.sourceContent` (the coordinator's binding), the `onContentChange` consumer, and the reset flag.
    private final class Record {
        var bound = ""
        var handled: [String] = []
        var resetting = false
        var drops = 0
    }

    private func makeCoordinator(
        _ record: Record, windowToken: UUID = UUID()
    ) -> CodeMirrorEditor.Coordinator {
        let coordinator = CodeMirrorEditor.Coordinator(
            content: Binding(get: { record.bound }, set: { record.bound = $0 }),
            cursorPositionToRestore: .constant(nil),
            scrollToOffset: .constant(nil),
            scrollToAnnotationIndex: .constant(nil),
            isResettingContent: Binding(get: { record.resetting }, set: { record.resetting = $0 }),
            onContentChange: { text, _ in record.handled.append(text) },
            onStatsChange: { _, _ in },
            onSectionChange: { _ in },
            onCursorPositionSaved: { _ in },
            onWebViewReady: nil,
            windowToken: windowToken)
        coordinator.isEditorReady = true
        coordinator.onContentPushDropped = { record.drops += 1 }
        return coordinator
    }

    @Test("handleContentPush tells the owner about typed text it drops: rebuild reset, busy state, grace; not echoes, not accepted pushes")
    func droppedTypingOwesAPull() {
        let record = Record()
        let coordinator = makeCoordinator(record)

        // A rebuild runs: isResettingContent is up (the first guard) and the content state is busy.
        record.resetting = true
        coordinator.contentState = .bibliographyUpdate
        coordinator.handleContentPush("typed during a rebuild")
        #expect(record.drops == 1, "a dropped contentChanged owed no pull (rebuild reset)")
        record.resetting = false

        coordinator.handleContentPush("typed while the state is busy")
        #expect(record.drops == 2, "a dropped contentChanged owed no pull (content state busy)")
        #expect(record.handled.isEmpty, "premise: nothing was accepted")

        // An echo of what is already known tells nothing.
        coordinator.lastPushedContent = "known text"
        coordinator.handleContentPush("known text")
        #expect(record.drops == 2, "an echo owed a pull")
        coordinator.contentState = .idle

        // Inside the grace after a Swift push, typed text is dropped.
        coordinator.lastPushTime = Date()
        coordinator.handleContentPush("typed inside the grace")
        #expect(record.drops == 3, "a dropped contentChanged owed no pull (150 ms grace)")

        // Outside the grace an idle push is accepted and owes nothing.
        coordinator.lastPushTime = .distantPast
        coordinator.handleContentPush("typed when nothing blocks it")
        #expect(record.drops == 3, "an accepted push owed a pull")
        #expect(record.handled == ["typed when nothing blocks it"])
        #expect(record.bound == "typed when nothing blocks it")
    }

    @Test("adoptMarkdownPageText makes the page's text the content record synchronously, only for its own window, and starts no push grace")
    func adoptingThePageTextIsSynchronousAndWindowScoped() {
        let editorState = EditorViewState()
        let record = Record()
        let coordinator = makeCoordinator(record, windowToken: editorState.windowToken)
        let other = Record()
        let otherCoordinator = makeCoordinator(other, windowToken: UUID())

        editorState.adoptMarkdownPageText("<!-- @sid:ab-12 -->## Notes\n\n[^1]: Typed note.")

        #expect(record.bound == "<!-- @sid:ab-12 -->## Notes\n\n[^1]: Typed note.", "the adoption was not complete when the post returned")
        #expect(record.handled == ["<!-- @sid:ab-12 -->## Notes\n\n[^1]: Typed note."], "onContentChange did not take the page's text")
        #expect(coordinator.lastPushedContent == record.bound, "shouldPushContent would push the adopted text back into the page")
        #expect(coordinator.lastPushTime == .distantPast, "the adoption started the 150 ms push grace")
        #expect(other.bound.isEmpty && other.handled.isEmpty && otherCoordinator.lastPushedContent.isEmpty,
                "another window adopted this window's text")
    }
}
