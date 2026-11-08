//
//  SwitchFlushTestSupport.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C7a: the entry the real-WebView XCTest classes of the close / switch save sequence
//  use (`SwitchFlushDuplicateInsertTests`, `ListConversionRoundTripTests`). The sibling of `QuitFlushTestSupport`:
//  it arms a token of the given kind on the editor state and runs the save sequence
//  (`EditorViewState.runLifecycleFlush`, steps 0-8) with production bounds and a host whose only live closure
//  hands out the editor's WebView, then does what `LifecycleEntry.execute`'s `finish` does -- releases the writer
//  barrier the sequence leaves held and clears the token -- so the temporary project can be read afterwards.
//
//  These XCTest classes deliberately do NOT go through `LifecycleEntry.run`: XCTest cases are not serialized
//  against the Swift Testing suites that own `LifecycleEntry`'s process-global state (`LifecycleEntryStatic`), and
//  what they pin is the save sequence's effect on the database, which is the same call.
//

import Foundation
import WebKit
@testable import final_final

@MainActor
enum SwitchFlushTestSupport {

    /// Arms a token of `kind` on `editorState`, as `LifecycleEntry.run` does. nil if it could not.
    static func arm(_ editorState: EditorViewState, kind: LifecycleKind) -> LifecycleToken? {
        guard case .armed(let token) = editorState.armLifecycle(kind, wasGettingStarted: false) else { return nil }
        return token
    }

    /// What `waitForPendingEdit` last observed.
    struct PendingEditObservation {
        /// The editor's Markdown (`window.FinalFinal.getContent()`).
        var content: String
        /// Whether the page still held a report of it not yet acknowledged (informational: with the editor's reports, Phase 5
        /// B3/B4, an edit leaves the page within about half a second and is acknowledged once applied; before that it was held
        /// as a pending change until the 2-second poll took it). nil if the JS call answered something else.
        var heldInOutbox: Bool?
        /// The caller's expectation held on `content`.
        var contentMatches: Bool

        /// The editor shows the edit.
        var isReady: Bool { contentMatches }
    }

    /// Waits (bounded, polling every 100ms) until the editor shows the typed edit (`isExpected(content)`), instead of sleeping a
    /// fixed time and probing once. It only READS (`getContent`, `reportOutboxSince`), so it never consumes anything. Returns the last
    /// observation either way; the caller reports which half failed. The expectation is about the Markdown the editor
    /// SERIALIZES (a bullet list comes back as `* item`, not `- item`), so state it as the shape, not as the keys typed.
    static func waitForPendingEdit(
        _ helper: EditorTestHelper,
        timeout: TimeInterval = 5,
        isExpected: (String) -> Bool
    ) async throws -> PendingEditObservation {
        let end = Date().addingTimeInterval(timeout)
        var observation = PendingEditObservation(content: "", heldInOutbox: nil, contentMatches: false)
        while true {
            let content = try await helper.getContent()
            let held = try await helper.webView.evaluateJavaScript(Self.outboxNotEmptyScript) as? Bool
            observation = PendingEditObservation(content: content, heldInOutbox: held, contentMatches: isExpected(content))
            if observation.isReady || Date() >= end { return observation }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// True when the Rich Text page holds a report not yet acknowledged.
    static let outboxNotEmptyScript =
        "(() => { const o = window.FinalFinal.reportOutboxSince ? window.FinalFinal.reportOutboxSince(null, 0) : null; "
        + "return !!(o && o.entries.length > 0); })()"

    /// The close / switch save sequence under the armed `token`, production bounds. A rebuild task already running
    /// when this is called is what step 3 awaits to completion before F.
    @discardableResult
    static func flush(
        _ editorState: EditorViewState,
        token: LifecycleToken,
        webView: WKWebView?
    ) async -> LifecycleFlushResult {
        let bounds = LifecycleBounds.production
        let result = await editorState.runLifecycleFlush(
            token: token,
            host: QuitFlushTestSupport.host(webView: webView),
            structuralUndoController: nil,
            deadline: LifecycleDeadline(total: bounds.closeTotal),
            bounds: bounds
        )
        // `LifecycleEntry.execute`'s finish: the barrier is released after every outcome and the token cleared.
        editorState.lifecycleBarrier?.release()
        editorState.lifecycleBarrier = nil
        editorState.clearLifecycle(token.id)
        return result
    }
}
