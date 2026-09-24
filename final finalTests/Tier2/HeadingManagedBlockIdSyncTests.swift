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
    private func makeStack(content: String = HeadingManagedBlockIdSyncTests.doc) async throws -> EditorStack {
        let db = try TestFixtureFactory.createTemporary(content: content)
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

    // MARK: - preserveUserBlocks plumbing (t-6a0d195d)

    /// Round-3 review (#18): the previous version of this test only asserted non-nil/nil,
    /// which every `preserveUserBlocks` code path returns on SOME leg (the pending-content
    /// stash, the empty-content branch, the ordinary fallback, AND a genuine merge) -- it
    /// proved the flag reached the page, not that the MERGE branch specifically ran. This
    /// version proves that directly: place the caret in a live, real WKWebView document,
    /// type a real in-window edit via the SAME public bridge calls
    /// `CitationRevertScrollBridgeTests.swift` uses for cursor placement
    /// (`setCursorPosition`/here, `insertAtCursor`), THEN push a rebuild whose db markdown
    /// still has the pre-edit text for that block but fresh managed content -- and assert the
    /// RETURNED merged markdown contains the live edit. Only a genuine merge (not the ordinary
    /// fallback, which returns the unmerged db markdown verbatim) could produce that.
    private static let mergeDoc = "# Heading\n\nP.\n\n## Bibliography\n\nOld entry."
    private static let mergeHeadingId = "merge-heading-id"
    private static let mergeParagraphId = "merge-p-id"
    private static let mergeBibHeadingId = "merge-bib-heading-id"
    private static let mergeBibEntryOldId = "merge-bib-entry-old-id"
    private static let mergeBibEntryNewId = "merge-bib-entry-new-id"

    @MainActor
    func testSetContentWithBlockIds_preserveUserBlocks_mergeBranchPreservesLiveInWindowEdit() async throws {
        let stack = try await makeStack(content: Self.mergeDoc)
        let (helper, sync) = (stack.helper, stack.sync)

        await sync.setContentWithBlockIds(
            markdown: Self.mergeDoc,
            blockIds: [Self.mergeHeadingId, Self.mergeParagraphId, Self.mergeBibHeadingId, Self.mergeBibEntryOldId],
            managedBlockIds: [Self.mergeBibHeadingId, Self.mergeBibEntryOldId]
        )
        try await Task.sleep(nanoseconds: 500_000_000)

        // Place the caret at the end of "P." (line 3, column 2 -- 1-indexed markdown line,
        // same setCursorPosition({line, column}) bridge call CitationRevertScrollBridgeTests
        // uses) and type a real, live edit via insertAtCursor -- exactly the scenario the
        // merge exists to protect.
        _ = try await helper.webView.evaluateJavaScript(
            "window.FinalFinal.setCursorPosition({line: 3, column: 2})"
        )
        _ = try await helper.webView.evaluateJavaScript(
            "window.FinalFinal.insertAtCursor(' EDITED')"
        )
        try await Task.sleep(nanoseconds: 300_000_000)

        // The rebuild push: the database still has P's OLD text (hasn't caught up with the
        // live edit above), but a freshly regenerated bibliography entry -- same shape as
        // rebuild-preserve-user-blocks.test.ts's (a)/(a2).
        let dbMarkdown = "# Heading\n\nP.\n\n## Bibliography\n\nNew entry."
        let merged = await sync.setContentWithBlockIds(
            markdown: dbMarkdown,
            blockIds: [Self.mergeHeadingId, Self.mergeParagraphId, Self.mergeBibHeadingId, Self.mergeBibEntryNewId],
            managedBlockIds: [Self.mergeBibHeadingId, Self.mergeBibEntryNewId],
            preserveUserBlocks: true
        )

        XCTAssertNotNil(merged, "the merge branch must have run and returned merged markdown")
        XCTAssertTrue(
            merged?.contains("P. EDITED") ?? false,
            "the merge must preserve the LIVE, in-window edit to P -- this is what proves the " +
                "MERGE branch specifically ran, not merely that some preserveUserBlocks path " +
                "returned non-nil. Got: \(merged ?? "nil")"
        )
        XCTAssertTrue(
            merged?.contains("New entry.") ?? false,
            "the merge must also carry in the freshly-pushed managed (bibliography) content. " +
                "Got: \(merged ?? "nil")"
        )
        XCTAssertFalse(
            merged?.contains("Old entry.") ?? true,
            "the stale managed content must not survive the merge. Got: \(merged ?? "nil")"
        )
    }

    /// Companion to the merge-branch test above: every pre-existing call site (omitting
    /// `preserveUserBlocks`) must keep returning nil, exactly as before this flag existed.
    @MainActor
    func testSetContentWithBlockIds_preserveUserBlocksOmitted_returnsNil() async throws {
        let stack = try await makeStack()
        let sync = stack.sync

        let omitted = await sync.setContentWithBlockIds(
            markdown: Self.doc,
            blockIds: [
                Self.managedHeadingId, Self.managedParagraphId,
                Self.unmanagedHeadingId, Self.unmanagedParagraphId,
            ],
            managedBlockIds: [Self.managedHeadingId]
        )
        XCTAssertNil(
            omitted,
            "every pre-existing call site omits preserveUserBlocks and must keep returning nil, " +
                "exactly as before this flag existed -- a non-nil return here means the flag " +
                "leaked into a push that never asked for it"
        )
    }
}
