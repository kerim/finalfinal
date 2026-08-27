//
//  MilkdownEditorReadyGateTests.swift
//  final finalTests
//
//  Tier 2: Coordinator-level tests for MilkdownEditor.Coordinator.
//  notifyWebViewReadyWhenEditorReady (t-18576cf7 fix).
//
//  Root cause: `didFinish`/`handlePreloadedView` fired `onWebViewReady?(webView)` the instant
//  WKWebView's page load finished -- but main.ts's `initEditor()` awaits
//  `Editor.make().create()` (~30 plugins) well after that. A project-open content push
//  (ContentView+ContentRebuilding.swift's `onWebViewReady` closure -> setContentWithBlockIds)
//  landing before that async mount completed got stashed by api-content.ts, then silently
//  dropped by main.ts's old replay guard -- the blank-pane bug. This fix gates
//  `onWebViewReady` behind `window.FinalFinal.isEditorReady()` actually reporting true (or a
//  3s timeout, so a genuinely broken JS environment doesn't leave the editor permanently
//  unresponsive).
//
//  Modelled on CodeMirrorContentPushGuardTests.swift's coordinator construction: a Coordinator
//  built via its plain init with `.constant(...)` bindings and NO real WKWebView navigation.
//  The readiness probe itself is overridable (`editorReadyProbe`, MilkdownEditor.swift) --
//  same seam CodeMirrorContentPushGuardTests uses to test `shouldPushContent` with `webView`
//  left nil -- so these tests never touch a real WKWebView JS engine. A bare `WKWebView()`
//  instance is still constructed (no `load()` call) purely so `notifyWebViewReadyWhenEditorReady`'s
//  `self.webView === webView` identity guard has something concrete to compare against.
//

import WebKit
import XCTest
@testable import final_final

@MainActor
final class MilkdownEditorReadyGateTests: XCTestCase {

    private func makeCoordinator() -> MilkdownEditor.Coordinator {
        MilkdownEditor.Coordinator(
            content: .constant(""),
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
            onWebViewReady: nil
        )
    }

    func testReadyPathFiresExactlyOnceEvenWhenBothCallSitesCallIn() {
        let coordinator = makeCoordinator()
        let webView = WKWebView(frame: .zero)
        coordinator.webView = webView

        var readyFireCount = 0
        coordinator.onWebViewReady = { _ in readyFireCount += 1 }
        coordinator.editorReadyProbe = { _, completion in completion(true) } // instantly "ready"

        // Simulate didFinish and handlePreloadedView both calling in -- only one should win.
        coordinator.notifyWebViewReadyWhenEditorReady(webView)
        coordinator.notifyWebViewReadyWhenEditorReady(webView)

        XCTAssertEqual(readyFireCount, 1, "onWebViewReady must fire exactly once, however many call sites call in.")
        XCTAssertTrue(coordinator.hasNotifiedWebViewReady)
    }

    func testTimeoutPathFiresExactlyOnceAfterTheRetryBudget() {
        let coordinator = makeCoordinator()
        let webView = WKWebView(frame: .zero)
        coordinator.webView = webView

        var readyFireCount = 0
        coordinator.onWebViewReady = { _ in readyFireCount += 1 }
        // Probe reports "not ready" forever -- proves the timeout branch fires regardless,
        // rather than polling indefinitely and never handing back a usable editor.
        coordinator.editorReadyProbe = { _, completion in completion(false) }

        // attempt: 60 is the retry budget's own >= 60 boundary (60 x 50ms = 3s) -- entering at
        // the boundary directly exercises the timeout branch deterministically and fast,
        // without a real 3s wait or a 60-iteration DispatchQueue.asyncAfter chain.
        coordinator.notifyWebViewReadyWhenEditorReady(webView, attempt: 60)

        XCTAssertEqual(readyFireCount, 1, "The 3s timeout must fire onWebViewReady exactly once.")
        XCTAssertTrue(coordinator.hasNotifiedWebViewReady)

        // A second call after the timeout already fired must be a no-op -- proves the timeout
        // branch also respects the fire-once token, not just the success branch.
        coordinator.notifyWebViewReadyWhenEditorReady(webView, attempt: 60)
        XCTAssertEqual(readyFireCount, 1, "A call after the timeout already fired must not fire again.")
    }

    func testTeardownBeforeTheProbeResolvesFiresZeroTimes() {
        let coordinator = makeCoordinator()
        let webView = WKWebView(frame: .zero)
        coordinator.webView = webView

        var readyFireCount = 0
        coordinator.onWebViewReady = { _ in readyFireCount += 1 }

        // Capture the probe's completion instead of calling it -- simulates a real
        // evaluateJavaScript round trip still in flight when teardown happens.
        var pendingCompletion: ((Bool) -> Void)?
        coordinator.editorReadyProbe = { _, completion in pendingCompletion = completion }

        coordinator.notifyWebViewReadyWhenEditorReady(webView)
        XCTAssertNotNil(pendingCompletion, "The probe should have been invoked and its completion captured.")

        // Teardown happens while the probe is still in flight (dismantleNSView's real path).
        coordinator.cleanup()
        XCTAssertTrue(coordinator.isCleanedUp)
        XCTAssertTrue(coordinator.hasNotifiedWebViewReady, "cleanup() must set this so an in-flight poll can't call back in.")

        // The in-flight probe now resolves -- must be a no-op against the torn-down coordinator.
        pendingCompletion?(true)

        XCTAssertEqual(readyFireCount, 0, "onWebViewReady must never fire once the coordinator has been torn down.")
    }

    func testStaleWebViewIdentityIsIgnored() {
        let coordinator = makeCoordinator()
        let originalWebView = WKWebView(frame: .zero)
        let replacementWebView = WKWebView(frame: .zero)
        coordinator.webView = originalWebView // torn down / re-mounted onto a different webView

        var readyFireCount = 0
        coordinator.onWebViewReady = { _ in readyFireCount += 1 }
        coordinator.editorReadyProbe = { _, completion in completion(true) }

        // A stale call scheduled against the OLD webView must be ignored once coordinator.webView
        // has moved on to a different instance.
        coordinator.notifyWebViewReadyWhenEditorReady(replacementWebView)

        XCTAssertEqual(readyFireCount, 0, "A call whose webView no longer matches coordinator.webView must be ignored.")
        XCTAssertFalse(coordinator.hasNotifiedWebViewReady)
    }

    // MARK: - MF1: batchInitialize's content push must never land pre-mount

    /// Pins the exact decision `performBatchInitialize` uses to compute `effectiveContent`
    /// (MilkdownCoordinator+MessageHandlers.swift). Before this fix, that decision was made
    /// from `isResettingContentBinding.wrappedValue` alone -- a proxy for "has onWebViewReady's
    /// push already happened" that stopped being reliable once `onWebViewReady` itself became
    /// gated behind the same mount signal tested here (`notifyWebViewReadyWhenEditorReady`
    /// above): `isResettingContent` stays false right up until `onWebViewReady` actually fires,
    /// so a batchInitialize() round trip that resolves BEFORE mount -- the common case, since
    /// `window.FinalFinal` exists at module load, long before `Editor.make().create()` resolves
    /// -- would push the full document via `initialize()` while the editor is still unmounted.
    /// That routes through api-modes.ts's `setContent()` no-instance branch, which stashes into
    /// the lossy `currentContent` slot instead of `pendingBlockContent` and gets replayed via a
    /// full re-parse that mints fresh TEMPORARY block IDs -- exactly the "destroying all real
    /// UUIDs" hazard this whole fix (t-18576cf7) exists to close.
    ///
    /// `effectiveBatchInitContent` must return "" whenever the editor isn't mounted yet,
    /// regardless of isResettingContent, so real content can ONLY ever reach the editor via a
    /// push that happens once mount is confirmed (either `performBatchInitialize` itself, next
    /// time it's asked with `editorMounted: true`, or the guaranteed-to-follow
    /// `onWebViewReady` -> `setContentWithBlockIds` push, which uses the block-ID-preserving
    /// path, never the lossy one).
    func testEffectiveBatchInitContentSkipsContentWhenEditorNotMounted() {
        let content = "# Real document content"

        XCTAssertEqual(
            MilkdownEditor.Coordinator.effectiveBatchInitContent(
                content: content, isResettingContent: false, editorMounted: false),
            "",
            "Not mounted yet, not resetting -- MUST still skip: this is the exact pre-mount race MF1 closes.")
        XCTAssertEqual(
            MilkdownEditor.Coordinator.effectiveBatchInitContent(
                content: content, isResettingContent: true, editorMounted: false),
            "",
            "Not mounted AND resetting -- skip for both reasons.")
        XCTAssertEqual(
            MilkdownEditor.Coordinator.effectiveBatchInitContent(
                content: content, isResettingContent: true, editorMounted: true),
            "",
            "Mounted, but onWebViewReady's own push is already in flight -- still skip.")
        XCTAssertEqual(
            MilkdownEditor.Coordinator.effectiveBatchInitContent(
                content: content, isResettingContent: false, editorMounted: true),
            content,
            "Mounted AND not resetting -- the only case where pushing real content here is safe.")
    }
}
