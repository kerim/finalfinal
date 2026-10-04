//
//  ListConversionRoundTripTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C7a (slice-3a-1b-everyday.md section 7.2 "C7a", plan-v3 U10, user step 5):
//  REGRESSION PIN for FB, the queued whole-document write the close / switch save sequence makes.
//
//  What it pins: a paragraph the user converts into a bullet list ("- " at its start) must not come back DUPLICATED
//  when the project is closed straight away and reopened. Block-sync cannot express "this paragraph row is now a
//  list": the force-send (F) applies the conversion as a new list row beside the old paragraph row, and only FB, the
//  whole-document replace that follows F, leaves the table matching the editor. This test passes against the
//  pre-lifecycle close path too (the old close flush ended in the same whole-document replace); it must STAY green
//  now that FB is a queued write. It guards the kept FB: if a later change drops or reorders it, this fails.
//
//  Flow: real Milkdown WebView, real NSEvent typing (execCommand does not replicate real keyboard input here), the
//  close save sequence (`SwitchFlushTestSupport`, step 0-8 under a CLOSE token), then the database is read as a
//  reopen would read it: exactly one row carries the typed word, it is a bullet list, the old paragraph is gone, and
//  the rows survive a second poll and a re-parse of their own Markdown unchanged (no structural diff for the first
//  poll after reopening to turn into duplicates).
//
//  Uses XCTest (not Swift Testing) because WKWebView requires a run loop -- same reasoning as
//  QuitFlushDuplicateInsertTests.swift, whose harness this copies.
//

import XCTest
import WebKit
@testable import final_final

final class ListConversionRoundTripTests: XCTestCase {

    private static let typedWord = "listwordzz"

    private static let doc = """
    # Alpha

    convert me please.

    # Beta

    four five six.
    """

    private var hostWindow: NSWindow?

    @MainActor
    override func tearDown() async throws {
        hostWindow?.orderOut(nil)
        hostWindow = nil
    }

    @MainActor
    func testParagraphConvertedToListThenImmediateClose_isNotDuplicated() async throws {
        let stack = try await makeStack()
        let (helper, db, pid, sync, editorState) = (stack.helper, stack.db, stack.pid, stack.sync, stack.editorState)
        guard let window = hostWindow else { throw XCTSkip("no host window") }
        defer { sync.stopPolling() }

        // The user puts the caret at the very start of the paragraph, types "- " (Milkdown turns the paragraph into a
        // bullet list) and a word, then closes at once.
        try await placeCursorAtStartOfParagraph(helper, startingWith: "convert me please.")
        try await Task.sleep(nanoseconds: 200_000_000)
        try typeViaNSEvents("- ", window: window)
        try await Task.sleep(nanoseconds: 300_000_000)
        try typeViaNSEvents(Self.typedWord, window: window)

        // Wait on what is true, not on a fixed sleep: the editor SERIALIZES a bullet list as `* item` (Milkdown's marker),
        // never `- item`, so the converted paragraph is recognised by its SHAPE -- a list-marker line starting with the
        // typed word -- and block-sync must still hold the conversion as a pending change. (The first version of this
        // probe looked for the literal "- " the user typed and failed on the editor's own `* ` output.)
        let typedLine = "(?m)^[ \\t]*[-*+][ \\t]+\(Self.typedWord)"
        let observed = try await SwitchFlushTestSupport.waitForPendingEdit(helper) { markdown in
            markdown.range(of: typedLine, options: .regularExpression) != nil
        }
        XCTAssertTrue(
            observed.contentMatches,
            "the paragraph never became a bullet list starting with the typed word; editor content=\(observed.content)")
        XCTAssertEqual(
            observed.hasPendingChanges, true,
            "the conversion is not held as a pending block-sync change; content=\(observed.content)")
        guard observed.isReady else { return }

        // Close: the save sequence (F, fresh fetch, FB, barrier), as `LifecycleEntry.run(.close)` runs it before `perform`.
        guard let token = SwitchFlushTestSupport.arm(editorState, kind: .close) else { return XCTFail("could not arm the close token") }
        let result = await SwitchFlushTestSupport.flush(editorState, token: token, webView: helper.webView)
        XCTAssertEqual(result.outcome, .flushed)
        XCTAssertEqual(
            result.fbSettledOutcome, .applied,
            "FB (the whole-document write) must have applied (the barrier waited for it); status \(result.fbStatus)")

        // Reopen: read the project as opening it would.
        let blocks = try TestFixtureFactory.fetchBlocks(from: db).sorted { $0.sortOrder < $1.sortOrder }
        let withWord = blocks.filter { $0.markdownFragment.contains(Self.typedWord) }
        let describedRows = withWord.map { "\($0.blockType.rawValue):\($0.markdownFragment)" }
        XCTAssertEqual(withWord.count, 1, "exactly ONE row may carry the converted item; found \(withWord.count): \(describedRows)")
        XCTAssertEqual(
            withWord.first?.blockType, .bulletList,
            "the converted paragraph is a bullet list, got \(String(describing: withWord.first?.blockType))")
        let leftovers = blocks.filter { $0.blockType == .paragraph && $0.markdownFragment.contains("convert me please.") }
        XCTAssertTrue(leftovers.isEmpty, "the old paragraph row must be gone, not left beside the list: \(leftovers.map(\.markdownFragment))")
        XCTAssertEqual(
            blocks.filter { $0.markdownFragment.contains("convert me please.") }.count, 1,
            "the old text appears once (inside the list item), not once per row"
        )
        XCTAssertTrue(blocks.contains { $0.blockType == .paragraph && $0.markdownFragment.contains("four five six.") }, "Beta untouched")

        // The rows are stable under a second poll and a re-parse of their own Markdown: the first poll after a reopen
        // sees no structural difference to turn into inserts.
        await sync.pollBlockChangesNow()
        let afterPoll = try TestFixtureFactory.fetchBlocks(from: db).sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(afterPoll.count, blocks.count, "a second poll must not add or remove rows")
        let reassembled = BlockParser.assembleMarkdown(from: afterPoll)
        let reparsed = BlockParser.parse(markdown: reassembled, projectId: pid)
        XCTAssertEqual(
            reparsed.filter { $0.markdownFragment.contains(Self.typedWord) }.count, 1,
            "re-parsing the saved Markdown must give the list once"
        )
        XCTAssertEqual(reparsed.count, afterPoll.count, "re-parsing the saved Markdown must give the same number of rows")
    }
}

// MARK: - Harness
//
// Copied (not shared) from QuitFlushDuplicateInsertTests.swift / CloseFlushDuplicateInsertTests.swift; see their header
// comments for why each piece is shaped the way it is (real NSEvent typing, the rAF shim).

extension ListConversionRoundTripTests {
    /// Collapses the DOM selection to offset 0 of the first paragraph whose text starts with `text`.
    @MainActor
    private func placeCursorAtStartOfParagraph(_ helper: EditorTestHelper, startingWith text: String) async throws {
        let escaped = text.replacingOccurrences(of: "'", with: "\\'")
        let result = try await helper.webView.evaluateJavaScript(
            """
            (() => {
                const pm = document.querySelector('.ProseMirror');
                if (!pm) return 'no-prosemirror-root';
                const target = Array.from(pm.querySelectorAll('p')).find(p => (p.textContent || '').startsWith('\(escaped)'));
                if (!target) return 'no-paragraph';
                const textNode = target.firstChild;
                if (!textNode) return 'no-text-node';
                pm.focus();
                const range = document.createRange();
                range.setStart(textNode, 0);
                range.collapse(true);
                const sel = window.getSelection();
                sel.removeAllRanges();
                sel.addRange(range);
                return 'ok';
            })()
            """
        ) as? String
        XCTAssertEqual(result, "ok", "failed to place the caret at the start of the paragraph (diagnostic: \(String(describing: result)))")
    }

    @MainActor
    private func typeViaNSEvents(_ text: String, window: NSWindow) throws {
        for character in text {
            let charString = String(character)
            let now = ProcessInfo.processInfo.systemUptime
            guard
                let down = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: now, windowNumber: window.windowNumber, context: nil,
                    characters: charString, charactersIgnoringModifiers: charString,
                    isARepeat: false, keyCode: 0
                ),
                let keyUp = NSEvent.keyEvent(
                    with: .keyUp, location: .zero, modifierFlags: [],
                    timestamp: now, windowNumber: window.windowNumber, context: nil,
                    characters: charString, charactersIgnoringModifiers: charString,
                    isARepeat: false, keyCode: 0
                )
            else {
                throw NSError(
                    domain: "list-conversion-test", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "could not build NSEvent for '\(charString)'"]
                )
            }
            window.sendEvent(down)
            window.sendEvent(keyUp)
        }
    }

    private struct EditorStack {
        let helper: EditorTestHelper
        let db: ProjectDatabase
        let pid: String
        let sync: BlockSyncService
        let editorState: EditorViewState
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
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(helper.webView)
        hostWindow = window

        try await helper.loadAndWaitForReady(timeout: 15)

        // Harness shim: WKWebView under xcodebuild never fires requestAnimationFrame (see QuitFlushDuplicateInsertTests).
        _ = try await helper.webView.evaluateJavaScript(
            "window.requestAnimationFrame = (cb) => setTimeout(() => cb(performance.now()), 16); true"
        )

        let editorState = EditorViewState()
        let sync = BlockSyncService()
        sync.configure(database: db, projectId: pid, webView: helper.webView)
        sync.editorState = editorState
        editorState.blockSyncService = sync
        editorState.projectDatabase = db
        editorState.currentProjectId = pid

        let blocks = try TestFixtureFactory.fetchBlocks(from: db).sorted { $0.sortOrder < $1.sortOrder }
        let ids = BlockParser.idsForProseMirrorAlignment(blocks)
        let content = BlockParser.assembleMarkdown(from: blocks)
        await sync.setContentWithBlockIds(markdown: content, blockIds: ids)
        try await Task.sleep(nanoseconds: 500_000_000)
        editorState.content = content

        return EditorStack(helper: helper, db: db, pid: pid, sync: sync, editorState: editorState)
    }
}
