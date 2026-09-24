//
//  CAYWConcurrentInsertTests.swift
//  final finalTests
//
//  Tier 2: Visible Breakage — end-to-end proof of the CAYW (Cite-As-You-Write)
//  position-tracking fix, driven through a real WKWebView and the real
//  Swift <-> JS bridge (not just the JS-level unit tests in
//  web/milkdown/src/__tests__/cayw.test.ts).
//
//  The bug this hardens against (web/milkdown/src/cayw.ts): the citation
//  picker's "where do I insert when Zotero answers" position used to live in
//  a single module-level singleton. The Zotero round-trip is a real async
//  HTTP call the app's UI does NOT block on, so a second citation request
//  opened before the first resolves would clobber the first's stored range,
//  and continued editing during either round-trip would leave stale raw
//  offsets pointing at the wrong content. The fix replaces the singleton with
//  `pendingCAYWRequests: Map<requestId, {start,end}>` keyed by a
//  monotonically-increasing `nextCAYWRequestId`, plus `caywRemapPlugin` (a
//  ProseMirror plugin) that remaps every pending entry's range across every
//  doc-changing transaction via `tr.mapping.map()`.
//
//  This file proves the fix survives the real bridge, not just direct TS
//  function calls in jsdom:
//    - a real WKScriptMessageHandler registered for "openCitationPicker",
//      matching MilkdownCoordinator+MessageHandlers.swift's exact message
//      shape (`message.body as? Int`, the bare requestId — see
//      handleOpenCitationPicker(requestId:) and
//      sendCitationPickerCancelled(webView:requestId:)).
//    - real cursor placement + a real `window.FinalFinal.insertCitation()`
//      call (the same JS entry point the native toolbar "Cite" button
//      invokes — see cayw.ts's insertCitationAtCursor doc comment).
//    - a real intervening edit typed via NSEvent keyDown/keyUp (per this
//      codebase's "execCommand doesn't replicate real keyboard input" rule),
//      not a hand-built ProseMirror transaction — so the position shift the
//      remap plugin has to track is the same kind of shift a real user
//      produces by continuing to type while Zotero's dialog is still open.
//    - real `window.FinalFinal.citationPickerCallback(...)` /
//      `citationPickerCancelled(...)` calls, resolved deliberately
//      out of order, plus `window.FinalFinal.getCAYWDebugState()` to inspect
//      the pending map directly.
//
//  Uses XCTest (not Swift Testing) because WKWebView requires a run loop —
//  same reason as CitationDeleteTests.swift.
//

import XCTest
import WebKit
@testable import final_final

final class CAYWConcurrentInsertTests: XCTestCase {

    var hostWindow: NSWindow?

    @MainActor
    override func tearDown() async throws {
        hostWindow?.orderOut(nil)
        hostWindow = nil
    }

    // MARK: - Test 1: overlapping requests, resolved out of order, across an intervening edit

    /// Core proof of the fix: two requests opened while both are still pending
    /// (no singleton clobbering), an intervening real edit that shifts both their
    /// stored ranges (proving caywRemapPlugin's tr.mapping.map() actually runs),
    /// and out-of-order resolution (proving the Map/requestId lookup — not
    /// insertion order, not "whichever was open" — decides where each citation
    /// lands).
    @MainActor
    func testOverlappingRequestsResolvedOutOfOrder_eachLandsAtCorrectShiftedPosition() async throws {
        let collector = CAYWRequestCollector()
        let helper = try await makeHelper(collector: collector)
        defer { helper.webView.configuration.userContentController.removeScriptMessageHandler(forName: "openCitationPicker") }
        guard let window = hostWindow else { throw XCTSkip("no host window") }

        try await helper.setContent(Self.originalMarkdown)

        // R1: cursor at end of the FIRST sentence.
        let firstRequestId = try await openCitationRequest(after: "First sentence here.", helper: helper, collector: collector)

        // R2: cursor at end of the SECOND sentence — opened BEFORE R1 resolves,
        // so both are simultaneously pending.
        let secondRequestId = try await openCitationRequest(after: "Second sentence here.", helper: helper, collector: collector)

        XCTAssertNotEqual(firstRequestId, secondRequestId, "each open should get its own distinct requestId")

        let debugBeforeEdit = try await caywDebugState(helper)
        XCTAssertEqual(debugBeforeEdit.pendingCAYWRequests.count, 2, "both requests should be pending before the intervening edit")

        // Intervening edit: real typing that shifts both R1's and R2's positions forward.
        try await performInterveningEdit(helper: helper, window: window)

        // Resolve OUT OF ORDER: R2 first, then R1.
        try await resolveCitation(helper, requestId: secondRequestId, citekey: "caywconcurrent2002", title: "CAYW Concurrent Insert Test Two")
        try await Task.sleep(nanoseconds: 300_000_000)
        try await resolveCitation(helper, requestId: firstRequestId, citekey: "caywconcurrent2001", title: "CAYW Concurrent Insert Test One")
        try await Task.sleep(nanoseconds: 300_000_000)

        let debugAfter = try await caywDebugState(helper)
        XCTAssertEqual(debugAfter.pendingCAYWRequests.count, 0, "both requests should be resolved, none left pending")

        let count = try await citationCount(helper)
        XCTAssertEqual(count, 2, "exactly two citation nodes should exist — no duplication, no dropped insert")

        let infos = try await citationInfos(helper)
        XCTAssertEqual(infos.count, 2)

        guard
            let citeOne = infos.first(where: { $0.citekeys == "caywconcurrent2001" }),
            let citeTwo = infos.first(where: { $0.citekeys == "caywconcurrent2002" })
        else {
            XCTFail("expected to find both citations by citekey, got: \(infos)")
            return
        }

        XCTAssertTrue(
            citeOne.paragraphText.contains("First sentence here."),
            "R1's citation should land next to the FIRST sentence, not be swapped:\n\(citeOne.paragraphText)"
        )
        XCTAssertFalse(
            citeOne.paragraphText.contains("Second sentence here."),
            "R1's citation must not land next to the SECOND sentence:\n\(citeOne.paragraphText)"
        )

        XCTAssertTrue(
            citeTwo.paragraphText.contains("Second sentence here."),
            "R2's citation should land next to the SECOND sentence, not be swapped:\n\(citeTwo.paragraphText)"
        )
        XCTAssertFalse(
            citeTwo.paragraphText.contains("First sentence here."),
            "R2's citation must not land next to the FIRST sentence:\n\(citeTwo.paragraphText)"
        )

        let content = try await helper.getContent()
        XCTAssertEqual(
            content.components(separatedBy: "First sentence here.").count - 1, 1,
            "the first sentence must appear exactly once (no duplication):\n\(content)"
        )
        XCTAssertEqual(
            content.components(separatedBy: "Second sentence here.").count - 1, 1,
            "the second sentence must appear exactly once (no duplication):\n\(content)"
        )
        XCTAssertTrue(content.contains("Prepended intro text."), "the intervening paragraph should still be present:\n\(content)")

        guard
            let firstRange = content.range(of: "First sentence here."),
            let citeOneRange = content.range(of: "caywconcurrent2001"),
            let secondRange = content.range(of: "Second sentence here."),
            let citeTwoRange = content.range(of: "caywconcurrent2002")
        else {
            XCTFail("expected all four markers present in exported markdown:\n\(content)")
            return
        }
        XCTAssertTrue(firstRange.upperBound <= citeOneRange.lowerBound, "R1's citekey should appear after the first sentence:\n\(content)")
        XCTAssertTrue(citeOneRange.upperBound <= secondRange.lowerBound, "R1's citekey should appear before the second sentence:\n\(content)")
        XCTAssertTrue(secondRange.upperBound <= citeTwoRange.lowerBound, "R2's citekey should appear after the second sentence:\n\(content)")
    }

    // MARK: - Test 2: cancel one, keep the other pending

    /// Proves cancellation is requestId-scoped: cancelling R1 removes ONLY R1 from
    /// the pending map, leaves document content untouched (insertCitationAtCursor's
    /// picker-open path has no /cite placeholder text to clean up — start === end
    /// === cursor position, unlike the /cite slash-command path in
    /// slash-commands.ts, which passes a non-empty [cmdStart, cmdEnd) range), and
    /// R2 survives — still correctly tracked across the SAME intervening edit — to
    /// resolve normally afterward.
    @MainActor
    func testCancellingOnePendingRequest_leavesOtherIntactAndStillResolvable() async throws {
        let collector = CAYWRequestCollector()
        let helper = try await makeHelper(collector: collector)
        defer { helper.webView.configuration.userContentController.removeScriptMessageHandler(forName: "openCitationPicker") }
        guard let window = hostWindow else { throw XCTSkip("no host window") }

        try await helper.setContent(Self.originalMarkdown)

        let firstRequestId = try await openCitationRequest(after: "First sentence here.", helper: helper, collector: collector)
        let secondRequestId = try await openCitationRequest(after: "Second sentence here.", helper: helper, collector: collector)
        XCTAssertNotEqual(firstRequestId, secondRequestId, "each open should get its own distinct requestId")

        try await performInterveningEdit(helper: helper, window: window)

        let contentBeforeCancel = try await helper.getContent()

        // Cancel R1 only.
        _ = try await helper.webView.evaluateJavaScript("window.FinalFinal.citationPickerCancelled(\(firstRequestId))")
        try await Task.sleep(nanoseconds: 300_000_000)

        let contentAfterCancel = try await helper.getContent()
        XCTAssertEqual(
            contentAfterCancel, contentBeforeCancel,
            "cancelling R1 must not alter document content (no /cite placeholder text existed for this insertion path)"
        )

        let countAfterCancel = try await citationCount(helper)
        XCTAssertEqual(countAfterCancel, 0, "no citation should exist yet — neither request has been resolved")

        let debugAfterCancel = try await caywDebugState(helper)
        XCTAssertEqual(
            debugAfterCancel.pendingCAYWRequests.map(\.requestId), [secondRequestId],
            "R1 should be gone from the pending map after cancelling it; R2 should remain, still tracked"
        )

        // R2 must still complete correctly, at its shifted position, despite
        // R1's cancellation and the shared intervening edit.
        try await resolveCitation(helper, requestId: secondRequestId, citekey: "caywconcurrent2102", title: "CAYW Cancel Test Two")
        try await Task.sleep(nanoseconds: 300_000_000)

        let countAfterResolve = try await citationCount(helper)
        XCTAssertEqual(countAfterResolve, 1, "R2 should resolve into exactly one citation node")

        let infos = try await citationInfos(helper)
        guard let citeTwo = infos.first(where: { $0.citekeys == "caywconcurrent2102" }) else {
            XCTFail("expected to find R2's citation by citekey, got: \(infos)")
            return
        }
        XCTAssertTrue(
            citeTwo.paragraphText.contains("Second sentence here."),
            "R2 should still land next to the SECOND sentence after R1 was cancelled:\n\(citeTwo.paragraphText)"
        )
        XCTAssertFalse(
            citeTwo.paragraphText.contains("First sentence here."),
            "R2 must not land next to the FIRST sentence:\n\(citeTwo.paragraphText)"
        )

        let debugFinal = try await caywDebugState(helper)
        XCTAssertEqual(debugFinal.pendingCAYWRequests.count, 0, "no pending requests should remain after cancel + resolve")
    }
}
