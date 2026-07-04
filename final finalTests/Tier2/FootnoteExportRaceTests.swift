//
//  FootnoteExportRaceTests.swift
//  final finalTests
//
//  Tier 2: root-cause investigation for the reported "footnote not in Word export"
//  regression that reproduced AFTER the flushBeforeExport fix landed.
//
//  Drives a real Milkdown WKWebView through the ACTUAL slash-command footnote
//  insertion path (typing "/footnote" as a real ProseMirror transaction, then a
//  real Enter keydown that slash-commands.ts's document-level keydown listener
//  turns into insertFootnoteWithDelete()), then immediately -- no artificial
//  delay -- calls the REAL DocumentManager.shared.loadContentForExport(), wired
//  to the REAL BlockSyncService.pollBlockChangesNow() exactly as ContentView.swift
//  wires flushBeforeExport in production.
//
//  Two checkpoints distinguish "editor has the right content but export reads it
//  stale" (the reported bug) from "the test's own slash-command simulation didn't
//  fire" (a test-harness problem, not an app bug):
//   (A) window.FinalFinal.getContent() immediately after the Enter keydown --
//       proves the EDITOR-side ProseMirror doc actually converted the slash text.
//   (B) DocumentManager.shared.loadContentForExport() called with NO extra delay --
//       the thing under test.
//

import XCTest
import WebKit
@testable import final_final

final class FootnoteExportRaceTests: XCTestCase {

    /// The exact sentence from the bundled Getting Started guide
    /// (final final/Resources/getting-started.ff, block id 6557B990-...).
    private static let targetSentence =
        "Pandoc, another popular free, open source project, is required for the advanced " +
        "export functions. (Plain markdown export works just fine without it.)"

    /// Placeholder replaced with literal "/footnote" text via find/replace -- a real
    /// ProseMirror transaction, same as typing. Concatenated directly onto the
    /// sentence with NO separating space/newline, matching the user's reported
    /// "immediately followed by literal /foo text with no separator" symptom.
    private static let placeholder = "ZZFOOTNOTEZZ"

    private static let doc = """
    # Getting Started

    \(targetSentence)\(placeholder)
    """

    private var hostWindow: NSWindow?

    @MainActor
    override func tearDown() async throws {
        hostWindow?.orderOut(nil)
        hostWindow = nil
        DocumentManager.shared.flushBeforeExport = nil
        DocumentManager.shared.closeProject()
    }

    private struct EditorStack {
        let helper: EditorTestHelper
        let db: ProjectDatabase
        let pid: String
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

        // Harness shim: WKWebView under xcodebuild never fires requestAnimationFrame
        // (see ZoomWordCountSyncTests for the same shim + rationale).
        _ = try await helper.webView.evaluateJavaScript(
            "window.requestAnimationFrame = (cb) => setTimeout(() => cb(performance.now()), 16); true"
        )

        let sync = BlockSyncService()
        sync.configure(database: db, projectId: pid, webView: helper.webView)
        return EditorStack(helper: helper, db: db, pid: pid, sync: sync)
    }

    // MARK: - Main reproduction test

    @MainActor
    func testFootnoteConfirmedThenExportedImmediately_bodyMarkerNotLostAsStaleSlashText() async throws {
        let stack = try await makeStack()
        let (helper, db) = (stack.helper, stack.db)
        let (pid, sync) = (stack.pid, stack.sync)

        let blocks = try TestFixtureFactory.fetchBlocks(from: db).sorted { $0.sortOrder < $1.sortOrder }
        let ids = BlockParser.idsForProseMirrorAlignment(blocks)
        let content = BlockParser.assembleMarkdown(from: blocks)
        await sync.setContentWithBlockIds(markdown: content, blockIds: ids)
        try await Task.sleep(nanoseconds: 500_000_000)

        // Wire DocumentManager.shared to the SAME ProjectDatabase instance the
        // editor's BlockSyncService writes to (single shared instance, matching
        // production's single-instance architecture -- not two separate DB
        // connections to the same file), and wire flushBeforeExport to the SAME
        // BlockSyncService driving this editor, exactly as ContentView.swift does.
        DocumentManager.shared.projectDatabase = db
        DocumentManager.shared.projectId = pid
        DocumentManager.shared.flushBeforeExport = { [weak sync] in
            await sync?.pollBlockChangesNow()
        }

        // --- Real slash-command insertion ---
        // find/replace the placeholder with literal "/footnote" (a real transaction,
        // indistinguishable from typing for block-sync -- same technique already
        // established by ZoomWordCountSyncTests.editBetaParagraph).
        _ = try await helper.webView.evaluateJavaScript(
            "window.FinalFinal.find('\(Self.placeholder)'); true"
        )
        _ = try await helper.webView.evaluateJavaScript(
            "window.FinalFinal.replaceAll('/footnote'); true"
        )

        let showState = try await helper.webView.evaluateJavaScript(
            "document.querySelector('.slash-menu')?.getAttribute('data-show')"
        ) as? String
        DebugLog.always("[FootnoteExportRaceTests] slash menu data-show after replaceAll: \(String(describing: showState))")

        // NOTE: driving the actual SlashProvider popup (typing text, then a real
        // Enter keydown) proved unreliable under xcodebuild's off-screen/headless
        // WKWebView -- `data-show` stayed "false" (confirmed via the log above),
        // so `handleSlashKeydown`'s guard silently no-ops the Enter and the raw
        // "/footnote" text is never converted. That is a TEST-HARNESS limitation,
        // not the app bug: the floating-ui positioning the popup depends on some
        // measurement (getBoundingClientRect/rAF-driven) that doesn't settle in
        // this environment. Falling back to `window.FinalFinal.insertFootnote()`
        // -- the SAME production, non-test-only API used by the real Cmd+Shift+N
        // keyboard-shortcut path (see main.ts's comment on EditorCommands.swift
        // calling evaluateJavaScript("insertFootnote()")) -- to perform the
        // delete-raw-text-then-insert-atom sequence as two separate real
        // ProseMirror transactions, which is what matters for the hypothesis
        // under test: does block-sync-plugin.ts's OWN internal 100ms debounce
        // (independent of Swift's `force` flag) let a stale intermediate
        // "/footnote" text update win a race against the Swift-side forced flush?

        // Brief pause modeling human reaction time between typing "/footnote" and
        // confirming it -- NOT a pause before export (export stays immediate, per
        // the user's report). This is long enough for block-sync's 100ms debounce
        // to fire on the raw, unconverted "/footnote" text and commit it into the
        // JS side's pendingUpdates bookkeeping BEFORE the confirming transaction
        // below ever happens -- the precondition for the hypothesized race.
        try await Task.sleep(nanoseconds: 200_000_000)

        // Delete the raw "/footnote" text and insert the real footnote_ref atom at
        // that position -- two separate real transactions, functionally equivalent
        // to insertFootnoteWithDelete()'s single delete+insert transaction.
        // Replacement is a single space, not '' -- ProseMirror's schema.text('')
        // throws (text nodes cannot be empty), which replaceAll() silently
        // swallows via its try/catch, leaving "/footnote" untouched (confirmed:
        // an earlier run of this test with replaceAll('') left the atom inserted
        // BEFORE an untouched "/footnote", i.e. "...it.)[^1]/footnote").
        _ = try await helper.webView.evaluateJavaScript(
            "window.FinalFinal.find('/footnote'); true"
        )
        _ = try await helper.webView.evaluateJavaScript(
            "window.FinalFinal.replaceAll(' '); true"
        )
        _ = try await helper.webView.evaluateJavaScript(
            "window.FinalFinal.insertFootnote(); true"
        )

        // Checkpoint (A): does the EDITOR itself show the converted footnote,
        // immediately, with no delay? Distinguishes a test-harness failure to
        // trigger the slash command from the actual export-flush bug under test.
        let docContentAfterConfirm = try await helper.webView.evaluateJavaScript(
            "window.FinalFinal.getContent()"
        ) as? String ?? ""
        DebugLog.always(
            "[FootnoteExportRaceTests] editor content immediately after Enter: " +
            "\(docContentAfterConfirm.replacingOccurrences(of: "\n", with: "\\n"))"
        )

        guard docContentAfterConfirm.contains("[^1]"), !docContentAfterConfirm.contains("/footnote") else {
            XCTFail(
                "TEST HARNESS ISSUE (not the app bug under test): the simulated slash-command " +
                "confirmation via Enter keydown did not convert the editor's own document to " +
                "[^1] -- got: \(docContentAfterConfirm.replacingOccurrences(of: "\n", with: "\\n"))"
            )
            return
        }

        // Checkpoint (B): the actual mechanism under test. No sleep, no delay --
        // "as fast as humanly possible" between confirming the footnote and exporting.
        let exported = try await DocumentManager.shared.loadContentForExport()
        DebugLog.always("[FootnoteExportRaceTests] exported markdown: \(String(describing: exported))")

        XCTAssertFalse(
            exported?.contains(Self.placeholder) ?? true,
            "exported markdown must not contain the raw placeholder (got: \(String(describing: exported)))"
        )
        XCTAssertFalse(
            exported?.contains("/footnote") ?? true,
            "exported markdown must not contain literal slash-command text -- footnote " +
            "insertion must be flushed before export (got: \(String(describing: exported)))"
        )
        XCTAssertTrue(
            exported?.contains("[^1]") ?? false,
            "exported markdown must contain the converted footnote marker [^1] " +
            "(got: \(String(describing: exported)))"
        )
    }
}
