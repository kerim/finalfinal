//
//  BlockIdAlignmentHardeningLiveTests.swift
//  final finalTests
//
//  Tier 2: end-to-end (real WKWebView + real JS + real Swift block model) coverage
//  for the setBlockIdsForTopLevel hardening in block-id-plugin.ts. That function now
//  takes an optional 3rd `expected: ExpectedBlockMeta[]` argument -- a per-slot
//  ground-truth {blockType, nonEmpty} check computed by BlockParser.alignmentPairs on
//  the Swift side. When a slot disagrees with the actual ProseMirror node at that
//  position, the id is WITHHELD (left untouched) rather than aliased onto the wrong
//  content -- see block-id-plugin.ts's setBlockIdsForTopLevel doc comment for the full
//  rationale (this defends against silently attaching a real DB row's identity to
//  content it doesn't belong to).
//
//  Substitutes for a manual Safari-Web-Inspector check: drives the REAL
//  window.FinalFinal.syncBlockIds bridge call (the exact JS entry point
//  BlockSyncService.pushBlockIds() calls in production) against a REAL Milkdown
//  WKWebView, using REAL Swift-side metadata computed by the actual
//  BlockParser.alignmentPairs()/BlockParser.parse() production code -- not hand-typed
//  JSON. Also verifies the `ALIGNMENT MISMATCH` diagnostic actually reaches Swift via a
//  WKScriptMessageHandler registered directly on the test's own webview (mirrors the
//  established SelectionMessageCollector pattern in ZoomWordCountSyncTests.swift --
//  EditorTestHelper's webview does not register an "errorHandler" handler by default,
//  so block-id-plugin.ts's postMessage call silently no-ops via optional chaining
//  without this).
//
//  Test 1 proves the hardening actually withholds on a genuine mismatch and reports it.
//  Test 2 proves the citation-atom exemption doesn't cause a FALSE-POSITIVE withholding
//  of legitimately blank-but-cited paragraphs (a citation-only paragraph's ProseMirror
//  textContent is '' because the citation is an atom node, but Swift's own
//  extractTextContent() does not strip `[@key]` bracket syntax -- only the `[text](url)`
//  link/image forms are stripped -- so Swift's nonEmpty is genuinely true for this
//  content; see block-id-plugin.ts's CONTENT_CHECK_ATOM_EXEMPTIONS comment).
//
//  Both tests read current position->id assignments via a small test-only JS accessor,
//  `window.FinalFinal.__testGetBlockIds()`, added alongside this file in main.ts
//  following the exact existing `__testSnapshot()` test-only-hook convention (read-only,
//  delegates to the block-id plugin's pre-existing exported getAllBlockIds()).
//
//  Uses XCTest (not Swift Testing) because WKWebView requires a run loop.
//

import XCTest
import WebKit
import Foundation
@testable import final_final

/// Collects `errorHandler` postMessage payloads (block-id-plugin.ts's diagnostic
/// channel) for assertions. Mirrors ZoomWordCountSyncTests.swift's
/// SelectionMessageCollector pattern exactly (same nonisolated-hop-to-MainActor shape).
@MainActor
private final class ErrorHandlerMessageCollector: NSObject, WKScriptMessageHandler {
    private(set) var messages: [String] = []

    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any], let text = dict["message"] as? String else { return }
        Task { @MainActor in
            self.messages.append(text)
        }
    }
}

/// One entry from `window.FinalFinal.__testGetBlockIds()` (test-only accessor added
/// alongside this file -- see main.ts).
private struct BlockIdEntry: Decodable {
    let offset: Int
    let id: String
}

final class BlockIdAlignmentHardeningLiveTests: XCTestCase {

    private var hostWindows: [NSWindow] = []

    @MainActor
    override func tearDown() async throws {
        for window in hostWindows {
            window.orderOut(nil)
        }
        hostWindows.removeAll()
    }

    private struct EditorStack {
        let helper: EditorTestHelper
        let db: ProjectDatabase
        let sync: BlockSyncService
        let collector: ErrorHandlerMessageCollector
    }

    @MainActor
    private func makeStack(content: String) async throws -> EditorStack {
        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let helper = EditorTestHelper(editorType: .milkdown)

        // Register the errorHandler capture BEFORE navigation so it's present for the
        // whole page lifetime (see file header). helper.webView.configuration is the
        // SAME live configuration/userContentController the view was initialized with --
        // adding a handler to it post-construction is a supported, already-established
        // pattern in this test suite (ZoomWordCountSyncTests.SelectionMessageCollector).
        let collector = ErrorHandlerMessageCollector()
        helper.webView.configuration.userContentController.add(collector, name: "errorHandler")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = helper.webView
        window.orderFront(nil)
        hostWindows.append(window)

        try await helper.loadAndWaitForReady(timeout: 15)

        // Harness shim: WKWebView under xcodebuild never fires requestAnimationFrame
        // (see ZoomWordCountSyncTests/FootnoteExportRaceTests for the same shim + rationale).
        _ = try await helper.webView.evaluateJavaScript(
            "window.requestAnimationFrame = (cb) => setTimeout(() => cb(performance.now()), 16); true"
        )

        let sync = BlockSyncService()
        sync.configure(database: db, projectId: pid, webView: helper.webView)
        return EditorStack(helper: helper, db: db, sync: sync, collector: collector)
    }

    /// Reads window.FinalFinal.__testGetBlockIds(), sorted by document offset (the JS
    /// accessor already sorts, but decoding order isn't a guarantee we want to lean on
    /// twice, so this stays explicit about what it returns).
    @MainActor
    private func readBlockIds(_ helper: EditorTestHelper) async throws -> [BlockIdEntry] {
        let json = try await helper.webView.evaluateJavaScript(
            "JSON.stringify(window.FinalFinal.__testGetBlockIds())"
        ) as? String
        guard let json, let data = json.data(using: .utf8) else {
            throw EditorTestError.snapshotFailed
        }
        return try JSONDecoder().decode([BlockIdEntry].self, from: data)
    }

    /// Encodes a plain Codable value (UUID strings / BlockAlignmentMeta arrays --
    /// never arbitrary user content) directly into JS-array/object-literal syntax.
    /// JSON is a syntactic subset of JS expression literals, so no `JSON.parse`/
    /// template-literal-escaping dance is needed here, unlike BlockSyncService's
    /// production code, which additionally escapes backticks/`${` because it carries
    /// arbitrary user markdown through the same channel.
    private func jsonString(_ value: some Encodable) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8)!
    }

    // MARK: - Test 1: mismatched `expected` metadata is withheld, not aliased

    @MainActor
    func testMismatchedExpectedMetadata_idWithheldNotAliased_mismatchReported() async throws {
        // Uses a footnote definition (not a plain paragraph) for the slot under test.
        // This is deliberate, not incidental: the check is ONE-DIRECTIONAL by design --
        // it only ever flags "expected non-blank, actual blank" (see block-id-plugin.ts's
        // setBlockIdsForTopLevel doc comment), the exact shape of the original historical
        // corruption (an existing footnote's real definition text landing on a blank
        // node). A blank footnote definition reliably parses to a real, well-understood
        // PM shape (paragraph > [footnote_def(atom), text(" ")], stub trims to "") that
        // was already exhaustively verified during this fix's plan review -- far more
        // reliable here than trying to construct an arbitrary "blank paragraph" via
        // whitespace/entity tricks, whose remark/micromark blank-line parsing semantics
        // aren't guaranteed the same way.
        let stack = try await makeStack(content: "# Heading\n\n[^1]: Some real footnote text.")
        defer { stack.helper.webView.configuration.userContentController.removeScriptMessageHandler(forName: "errorHandler") }
        let helper = stack.helper

        let blocks = try TestFixtureFactory.fetchBlocks(from: stack.db).sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(blocks.count, 2, "fixture must produce exactly 2 blocks (heading + footnote-definition paragraph)")
        XCTAssertEqual(blocks[0].blockType, .heading)
        XCTAssertEqual(blocks[1].blockType, .paragraph)
        XCTAssertFalse(
            blocks[1].textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "the footnote definition must have genuinely non-blank remainder text for this test to be meaningful"
        )

        let realIds = BlockParser.idsForProseMirrorAlignment(blocks)
        let content = BlockParser.assembleMarkdown(from: blocks)

        // Real Swift -> JS push: the SAME production entry point BlockSyncService uses
        // for the initial load. No `expected` passed here -- nothing to check yet.
        await stack.sync.setContentWithBlockIds(markdown: content, blockIds: realIds)
        try await Task.sleep(nanoseconds: 500_000_000)

        let before = try await readBlockIds(helper)
        XCTAssertEqual(before.map { $0.id }, realIds, "real DB ids must land at the right offsets after initial load")

        // "Stale" metadata: the REAL Swift alignmentPairs output computed from the
        // ORIGINAL, non-blank blocks above -- i.e. what a DB read taken BEFORE the live
        // document below gets blanked out from under it would say. This models a real
        // (markdown, blockIds/expected) pair going stale relative to the live document --
        // not hand-typed JSON pretending to be Swift's output.
        let staleExpected = BlockParser.alignmentPairs(blocks).map { $0.meta }
        XCTAssertEqual(staleExpected.count, 2)
        XCTAssertEqual(staleExpected[1].nonEmpty, true, "sanity: stale metadata must claim the real, non-blank remainder text")

        // Now blank the LIVE document at that same position via the same production entry
        // point, reusing the SAME ids (no `expected` on this call, so no check runs yet --
        // this only gets the actual document into a state that disagrees with the stale
        // metadata captured above).
        let blankedMarkdown = "# Heading\n\n[^1]: "
        await stack.sync.setContentWithBlockIds(markdown: blankedMarkdown, blockIds: realIds)
        try await Task.sleep(nanoseconds: 500_000_000)

        let afterBlanking = try await readBlockIds(helper)
        XCTAssertEqual(afterBlanking.map { $0.id }, realIds, "blanking push must not itself change ids (no expected passed)")

        // Deviation from the literal brief: push NEW, never-before-seen ids rather than
        // reusing the ids already at these offsets. Reusing the same ids would make
        // "withheld" (stays old) and "assigned" (becomes new) byte-identical outcomes --
        // unobservable, and would prove nothing about the hardening. Fresh ids make the
        // two outcomes distinguishable, and better model the actual bug class this
        // hardening prevents (a DB row's identity getting aliased onto the wrong node).
        let newHeadingId = UUID().uuidString
        let newParagraphId = UUID().uuidString
        let idsJSON = try jsonString([newHeadingId, newParagraphId])
        let expectedJSON = try jsonString(staleExpected)
        _ = try await helper.webView.evaluateJavaScript(
            "window.FinalFinal.syncBlockIds(\(idsJSON), false, \(expectedJSON)); true"
        )
        try await Task.sleep(nanoseconds: 300_000_000)

        let after = try await readBlockIds(helper)
        XCTAssertEqual(after.count, 2, "block count must not change -- withholding an id must not drop/duplicate the slot")

        // Heading: expected matched reality -> legitimately reassigned to the new id.
        XCTAssertEqual(after[0].id, newHeadingId, "matching slot should accept the pushed id")

        // Paragraph: expected disagreed with reality -> id must be WITHHELD, not aliased.
        XCTAssertNotEqual(
            after[1].id, newParagraphId,
            "mismatched slot must NOT be aliased onto the newly-pushed id (would silently attach a DB row's " +
            "identity to content that disagrees with it) -- got \(after[1].id)"
        )
        XCTAssertEqual(
            after[1].id, realIds[1],
            "mismatched slot should retain its previous (real, correct) id rather than taking on any new identity"
        )

        // The diagnostic must actually reach Swift.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(
            stack.collector.messages.contains { $0.contains("ALIGNMENT MISMATCH") },
            "expected an ALIGNMENT MISMATCH diagnostic via errorHandler, got: \(stack.collector.messages)"
        )
    }

    // MARK: - Test 2: citation-only paragraph does not produce a false-positive mismatch

    @MainActor
    func testCitationOnlyParagraph_noFalsePositiveMismatch_idCorrectlyAssigned() async throws {
        let stack = try await makeStack(content: "# Heading\n\n[@smith2020]")
        defer { stack.helper.webView.configuration.userContentController.removeScriptMessageHandler(forName: "errorHandler") }
        let helper = stack.helper

        let blocks = try TestFixtureFactory.fetchBlocks(from: stack.db).sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(blocks.count, 2, "fixture must produce exactly 2 blocks (heading + citation-only paragraph)")
        XCTAssertEqual(blocks[0].blockType, .heading)
        XCTAssertEqual(blocks[1].blockType, .paragraph)

        // Sanity on the premise this test exists to verify: Swift's own textContent
        // extraction does NOT strip `[@key]` citation bracket syntax (only the
        // `[text](url)` link/image forms are stripped -- see
        // MarkdownUtils.stripMarkdownSyntax), so the REAL Swift-computed metadata for
        // this block is genuinely nonEmpty:true, even though the ProseMirror document
        // will render it as a blank paragraph containing only a citation atom node.
        XCTAssertFalse(
            blocks[1].textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "sanity: Swift's own textContent for a citation-only block must be non-blank"
        )

        let realIds = BlockParser.idsForProseMirrorAlignment(blocks)
        let content = BlockParser.assembleMarkdown(from: blocks)
        await stack.sync.setContentWithBlockIds(markdown: content, blockIds: realIds)
        try await Task.sleep(nanoseconds: 500_000_000)

        let before = try await readBlockIds(helper)
        XCTAssertEqual(before.map { $0.id }, realIds)

        // Confirm the editor's own document actually parsed the citation (the premise
        // this exemption exists for) -- otherwise this test would pass for the wrong
        // reason (e.g. the citation plugin failing to register at all).
        let editorContent = try await helper.getContent()
        XCTAssertTrue(editorContent.contains("smith2020"), "editor must have parsed the citation, got: \(editorContent)")

        // Real Swift computation of `expected` -- CORRECT metadata, not fabricated.
        let realExpected = BlockParser.alignmentPairs(blocks).map { $0.meta }
        XCTAssertEqual(realExpected.count, 2)
        XCTAssertEqual(
            realExpected[1].nonEmpty, true,
            "sanity: Swift's real alignmentPairs output must say nonEmpty:true for the citation-only paragraph"
        )

        // Push a NEW id for both slots (same reasoning as Test 1: a reused id can't
        // distinguish "assigned" from "was already there") with the REAL, correct
        // expected metadata -- this models a legitimate confirmation push, not a
        // deliberately wrong one.
        let newHeadingId = UUID().uuidString
        let newParagraphId = UUID().uuidString
        let idsJSON = try jsonString([newHeadingId, newParagraphId])
        let expectedJSON = try jsonString(realExpected)
        _ = try await helper.webView.evaluateJavaScript(
            "window.FinalFinal.syncBlockIds(\(idsJSON), false, \(expectedJSON)); true"
        )
        try await Task.sleep(nanoseconds: 300_000_000)

        let after = try await readBlockIds(helper)
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(after[0].id, newHeadingId)
        XCTAssertEqual(
            after[1].id, newParagraphId,
            "the citation exemption must not cause a false-positive withholding of healthy, correctly-described content"
        )

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(
            stack.collector.messages.contains { $0.contains("ALIGNMENT MISMATCH") },
            "no mismatch should be reported for a correct push -- the citation exemption must prevent a false " +
            "positive, got: \(stack.collector.messages)"
        )
    }
}
