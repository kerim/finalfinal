//
//  MilkdownContentAdoptionPushTests.swift
//  final finalTests
//
//  Phase 5 job B3, second regression (docs/architecture/write-queue-plan/phase5/b3-notes.md, "Second regression: whole-document push
//  after quick undo (2026-11-08)"). The editor's `contentChanged` push is adopted by `handleContentPush`: `lastPushedContent` takes the
//  new text, then the content binding does. SwiftUI can run a view update inside that binding write, before the new value is stored
//  (seen in the VM: `[SYNC-DIAG:UpdateNSView] PUSHING content len=<old>` inside the `contentPush` span, right after `ACCEPTED`). That
//  update compared the OLD `content` with the NEW `lastPushedContent` and pushed the old whole document into the editor, wiping
//  the restored section, any typing and the editor's undo history. The rig's binding runs such an update (`shouldPushContent`, what
//  `updateNSView` asks) inside its setter, both before and after it stores the value.
//

import SwiftUI
import XCTest
@testable import final_final

@MainActor
final class MilkdownContentAdoptionPushTests: XCTestCase {

    func testViewUpdateInsideTheContentWritePushesNothing() {
        var stored = "# Chapter\n\nThe post-delete document."
        var decisions: [Bool] = []
        var coordinator: MilkdownEditor.Coordinator?
        let binding = Binding<String>(
            get: { stored },
            set: { newValue in
                // A view update before the store (the old text is still what `content` reads) and one after it.
                decisions.append(coordinator?.shouldPushContent(stored) ?? true)
                stored = newValue
                decisions.append(coordinator?.shouldPushContent(stored) ?? true)
            })
        let made = MilkdownEditor.Coordinator(
            content: binding,
            cursorPositionToRestore: .constant(nil),
            scrollToOffset: .constant(nil),
            scrollToBlockId: .constant(nil),
            isResettingContent: .constant(false),
            contentState: .idle,
            onContentChange: { _, _ in },
            onStatsChange: { _, _ in },
            onSectionChange: { _ in },
            onCursorPositionSaved: { _ in },
            onContentAcknowledged: nil,
            onWebViewReady: nil,
            windowToken: UUID()
        )
        coordinator = made
        made.isEditorReady = true
        made.lastPushedContent = stored   // the editor and Swift agree on the post-delete text

        let restored = "# Chapter\n\nThe post-delete document.\n\n# Restored\n\nThe section the quick undo put back."
        made.handleContentPush(restored)

        XCTAssertEqual(stored, restored, "the editor's text was adopted")
        XCTAssertEqual(decisions, [false, false],
                       "a view update inside the adoption must push nothing (the first entry is the update that saw the OLD text)")
        XCTAssertFalse(made.shouldPushContent(stored), "after the adoption the view has nothing to push")
        XCTAssertFalse(made.adoptingEditorContent)
    }
}
