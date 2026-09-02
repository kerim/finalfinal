//
//  CursorRestoreIdempotenceTests.swift
//  final finalTests
//
//  Tier 2: regression guard for the stale cursor-restore race.
//
//  The bug: `restoreCursorPositionIfNeeded()` is supposed to consume-and-clear
//  `cursorPositionToRestore` after using it once, but its clear
//  (`cursorPositionToRestoreBinding.wrappedValue = nil`) happened synchronously
//  inside `updateNSView` (a SwiftUI view-update pass), which log evidence showed
//  does NOT actually persist -- the same stale value got replayed on every
//  subsequent content-reset cycle, not just once. Concretely: user switches
//  Source -> WYSIWYG (saves a mode-switch cursor position to restore) -> user
//  inserts a footnote -> Stage E's `focusFootnoteDefinition` correctly places the
//  cursor in the new footnote definition -> ~100ms later the STALE mode-switch
//  restore fires again and overwrites the correct position.
//
//  The fix makes the consume-and-clear idempotent: `restoreCursorPositionIfNeeded()`
//  now tracks the last position it actually applied (`consumedCursorRestore`) and
//  no-ops if asked to apply the identical position again, closing the gap opened by
//  moving the clear off the main-thread view-update pass and onto an async dispatch.
//
//  Modelled on MilkdownEditorReadyGateTests.swift's coordinator construction: a
//  Coordinator built via its plain init with bindings and NO real WKWebView
//  navigation -- `restoreCursorPositionIfNeeded()` never touches `isEditorReady`
//  or `webView` directly (only the delayed `setCursorPosition`/`scrollToLine` calls
//  it may schedule do, and those simply no-op when the editor isn't ready), so a
//  bare Coordinator is sufficient here.
//

import SwiftUI
import WebKit
import XCTest
@testable import final_final

@MainActor
final class CursorRestoreIdempotenceTests: XCTestCase {

    // MARK: - Milkdown

    func testMilkdownRestoreCursorPositionIfNeededIsIdempotentAcrossStaleReplay() {
        let position = CursorPosition(line: 5, column: 3, scrollFraction: 0, cursorIsVisible: true, topLine: 1.0)
        var boxedValue: CursorPosition? = position
        let binding = Binding<CursorPosition?>(get: { boxedValue }, set: { boxedValue = $0 })

        let coordinator = MilkdownEditor.Coordinator(
            content: .constant(""),
            cursorPositionToRestore: binding,
            scrollToOffset: .constant(nil),
            scrollToBlockId: .constant(nil),
            isResettingContent: .constant(false),
            contentState: .idle,
            onContentChange: { _, _ in },
            onStatsChange: { _, _ in },
            onSectionChange: { _ in },
            onCursorPositionSaved: { _ in },
            onContentAcknowledged: nil,
            onWebViewReady: nil
        )

        coordinator.restoreCursorPositionIfNeeded()
        let workItemAfterFirstCall = coordinator.cursorRestoreWorkItem
        XCTAssertNotNil(workItemAfterFirstCall,
            "First call with a real (non-default) cursor position should schedule a restore.")

        // Simulate the exact bug this test guards against: the clear of the bound value
        // (now dispatched async, off the SwiftUI view-update pass where it was provably not
        // persisting) hasn't landed yet when the binding is observed again with the SAME
        // stale position still sitting in it -- e.g. a synthetic content-rebuild cycle
        // re-entering before the async clear runs.
        boxedValue = position

        coordinator.restoreCursorPositionIfNeeded()

        XCTAssertTrue(coordinator.cursorRestoreWorkItem === workItemAfterFirstCall,
            "A second call with the identical (stale-replayed) position must be a no-op: it " +
            "must NOT cancel-and-reschedule a new cursor-restore work item, which would mean " +
            "the stale position was applied a second time.")

        coordinator.cursorRestoreWorkItem?.cancel()
    }

    func testMilkdownRestoreCursorPositionIfNeededReappliesAfterSaveAndNotifyResetsGuard() {
        let position = CursorPosition(line: 5, column: 3, scrollFraction: 0, cursorIsVisible: true, topLine: 1.0)
        var boxedValue: CursorPosition? = position
        let binding = Binding<CursorPosition?>(get: { boxedValue }, set: { boxedValue = $0 })

        let coordinator = MilkdownEditor.Coordinator(
            content: .constant(""),
            cursorPositionToRestore: binding,
            scrollToOffset: .constant(nil),
            scrollToBlockId: .constant(nil),
            isResettingContent: .constant(false),
            contentState: .idle,
            onContentChange: { _, _ in },
            onStatsChange: { _, _ in },
            onSectionChange: { _ in },
            onCursorPositionSaved: { _ in },
            onContentAcknowledged: nil,
            onWebViewReady: nil
        )

        coordinator.restoreCursorPositionIfNeeded()
        let workItemAfterFirstCall = coordinator.cursorRestoreWorkItem
        XCTAssertNotNil(workItemAfterFirstCall)

        // A genuinely new save-cursor cycle (saveAndNotify) resets the idempotence guard, so
        // the SAME position saved again later is a legitimate restore, not a stale replay.
        // (isEditorReady is false here, so saveAndNotify takes its early-return path -- it
        // still must clear the guard before that early return, since that path is exactly
        // what a not-yet-ready editor takes.)
        coordinator.saveAndNotify()
        boxedValue = position

        coordinator.restoreCursorPositionIfNeeded()

        XCTAssertFalse(coordinator.cursorRestoreWorkItem === workItemAfterFirstCall,
            "After saveAndNotify() resets the guard, restoring the identical position again " +
            "must schedule a fresh work item, not be silently treated as an already-applied replay.")

        coordinator.cursorRestoreWorkItem?.cancel()
    }

    // MARK: - CodeMirror

    func testCodeMirrorRestoreCursorPositionIfNeededIsIdempotentAcrossStaleReplay() {
        let position = CursorPosition(line: 5, column: 3, scrollFraction: 0, cursorIsVisible: true, topLine: 1.0)
        var boxedValue: CursorPosition? = position
        let binding = Binding<CursorPosition?>(get: { boxedValue }, set: { boxedValue = $0 })

        let coordinator = CodeMirrorEditor.Coordinator(
            content: .constant(""),
            cursorPositionToRestore: binding,
            scrollToOffset: .constant(nil),
            scrollToAnnotationIndex: .constant(nil),
            isResettingContent: .constant(false),
            onContentChange: { _, _ in },
            onStatsChange: { _, _ in },
            onSectionChange: { _ in },
            onCursorPositionSaved: { _ in },
            onWebViewReady: nil
        )

        coordinator.restoreCursorPositionIfNeeded()
        let workItemAfterFirstCall = coordinator.cursorRestoreWorkItem
        XCTAssertNotNil(workItemAfterFirstCall,
            "First call with a real (non-default) cursor position should schedule a restore.")

        // Same stale-replay simulation as the Milkdown twin above.
        boxedValue = position

        coordinator.restoreCursorPositionIfNeeded()

        XCTAssertTrue(coordinator.cursorRestoreWorkItem === workItemAfterFirstCall,
            "A second call with the identical (stale-replayed) position must be a no-op for " +
            "CodeMirror's coordinator too.")

        coordinator.cursorRestoreWorkItem?.cancel()
    }
}
