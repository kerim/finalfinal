//
//  HeadingManagedBlockIdSyncTests.swift
//  final finalTests
//
//  Tier 2: Live-WebView proof for t-d7f6c3b6 must-fix 1 — proving Swift actually
//  delivers `managedBlockIds` end-to-end.
//
//  BlockSyncService.setContentWithBlockIds's `managedBlockIds` parameter (added for
//  the heading-zoom-affordance task) is serialized into the JS call it makes, and
//  block-id-plugin.ts stamps `data-managed` on the DOM nodes named in that set --
//  block-id-dom-decoration.test.ts already proves the JS plugin does the right thing
//  GIVEN the ids. And ZoomExitPillTests (Tier 1) separately proves a Swift-side
//  router respects the managed flag. Neither test proves the Swift call site's
//  serialization actually reaches a *running* WKWebView and lands on the real DOM --
//  which is exactly the class of bug that originally parked this task ("the
//  mechanism never reached the real WYSIWYG editor"). This test drives a real
//  Milkdown WKWebView the same way ZoomWordCountSyncTests.swift does: push content
//  via `await sync.setContentWithBlockIds(...)`, then read the live DOM back via
//  `helper.webView.evaluateJavaScript(...)`.
//
//  Uses XCTest (not Swift Testing) because WKWebView requires a run loop.
//

import XCTest
import WebKit
@testable import final_final

final class HeadingManagedBlockIdSyncTests: XCTestCase {

    /// Two headings -- one flagged managed (mirrors a Bibliography heading), one not.
    private static let doc = """
    # Bibliography

    Ref A.

    # Notes

    Ref B.
    """

    private static let managedHeadingId = "bib-heading-id"
    private static let managedParagraphId = "bib-para-id"
    private static let unmanagedHeadingId = "notes-heading-id"
    private static let unmanagedParagraphId = "notes-para-id"

    /// Keeps the WebView on-screen; mirrors ZoomWordCountSyncTests's rationale
    /// (block-sync's deferredSnapshotAndUnpause() needs requestAnimationFrame, which
    /// an offscreen WKWebView never runs). Not strictly required for this test's own
    /// assertions (decoration is a synchronous ProseMirror dispatch, no rAF involved),
    /// but kept for parity with the harness pattern this test is modeled on.
    private var hostWindow: NSWindow?

    @MainActor
    override func tearDown() async throws {
        hostWindow?.orderOut(nil)
        hostWindow = nil
    }

    private struct EditorStack {
        let helper: EditorTestHelper
        let sync: BlockSyncService
    }

    @MainActor
    private func makeStack() async throws -> EditorStack {
        let db = try TestFixtureFactory.createTemporary(content: Self.doc)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let helper = EditorTestHelper(editorType: .milkdown)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = helper.webView
        window.orderFront(nil)
        hostWindow = window

        try await helper.loadAndWaitForReady(timeout: 15)

        let sync = BlockSyncService()
        sync.configure(database: db, projectId: pid, webView: helper.webView)
        return EditorStack(helper: helper, sync: sync)
    }

    /// Reads `data-managed` for a given `data-block-id` off the live DOM.
    @MainActor
    private func isManaged(_ blockId: String, in webView: WKWebView) async throws -> Bool {
        try await webView.evaluateJavaScript(
            "document.querySelector('[data-block-id=\"\(blockId)\"]')?.hasAttribute('data-managed') ?? false"
        ) as? Bool ?? false
    }

    // MARK: - End-to-end managedBlockIds plumbing

    /// Proves setContentWithBlockIds's `managedBlockIds` parameter reaches the real
    /// WYSIWYG editor: the heading named in the set gets `data-managed` on its live
    /// DOM node, and a sibling heading NOT named in the set does not.
    @MainActor
    func testSetContentWithBlockIds_managedBlockIds_reachesLiveDOM() async throws {
        let stack = try await makeStack()
        let (helper, sync) = (stack.helper, stack.sync)

        await sync.setContentWithBlockIds(
            markdown: Self.doc,
            blockIds: [
                Self.managedHeadingId, Self.managedParagraphId,
                Self.unmanagedHeadingId, Self.unmanagedParagraphId,
            ],
            managedBlockIds: [Self.managedHeadingId]
        )
        try await Task.sleep(nanoseconds: 500_000_000)

        let managedIsFlagged = try await isManaged(Self.managedHeadingId, in: helper.webView)
        XCTAssertTrue(
            managedIsFlagged,
            "the heading named in managedBlockIds must carry data-managed on the live DOM " +
                "(this is the plumbing must-fix: Swift's serialization must actually reach the " +
                "running WKWebView, not just the JS plugin in isolation)"
        )

        let unmanagedIsFlagged = try await isManaged(Self.unmanagedHeadingId, in: helper.webView)
        XCTAssertFalse(
            unmanagedIsFlagged,
            "a heading NOT named in managedBlockIds must NOT carry data-managed -- otherwise " +
                "the ⌘-hover zoom hint (styles.css) would wrongly stay hidden on every heading"
        )
    }
}
