//
//  ListConversionRoundTripTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C7a (slice-3a-1b-everyday.md section 7.2 "C7a", plan-v3 U10, user step 5):
//  REGRESSION PIN for FB, the queued whole-document write the close / switch save sequence makes.
//
//  What it pins: a paragraph the user converts into a bullet list ("- " at its start) must not come back DUPLICATED
//  when the project is closed straight away and reopened. This test passes against the pre-lifecycle close path too
//  (the old close flush ended in the same whole-document replace); it must STAY green now that FB is a queued write.
//
//  Phase 3a-2 changed WHY it is green, and what it expects (plan-v2 U-C2, "checked FB", Option A per the user's
//  decision). Step 1 makes the per-edit path store the conversion correctly (see `testParagraphConvertedToList_rowIsListWithoutFB`
//  below), and FB now compares before it writes. Until t-4eb7bfa9 the comparison said "different" after a list edit: the
//  per-block serializer stored the item as `- word`, the whole-document serializer fetched `* word`, so FB RAN
//  (`fbSettledOutcome == .applied`; the safety net in action). t-4eb7bfa9 made the per-block text Milkdown's own
//  serializer's piece of the whole-document text, so both write `* word` and the stored row is exactly what FB would
//  write: the same close now ends `.unchanged` (nothing rebuilt), with the same single-row assertions on the table
//  afterwards. The skip is also pinned by `testPlainProseSession_closeReachesUnchanged` (plain paragraphs and headings) and,
//  for the shapes the old per-block converter wrote differently, by `testRichTextShapes_closeReachesUnchanged`.
//
//  Phase 3a-2 also adds `testPlainProseSession_closeReachesUnchanged` (plan-v2 U-C2b): a session that only changed
//  plain paragraph and heading text closes with FB `.unchanged`, writing nothing.
//
//  Flow: real Milkdown WebView, real NSEvent typing (execCommand does not replicate real keyboard input here), the
//  close save sequence (`SwitchFlushTestSupport`, step 0-8 under a CLOSE token), then the database is read as a
//  reopen would read it: exactly one row carries the typed word, it is a bullet list, the old paragraph is gone, and
//  the rows survive a second poll and a re-parse of their own Markdown unchanged (no structural diff for the first
//  poll after reopening to turn into duplicates).
//
//  Phase 3a-2, Step 1 (plan-v2 U-B2) adds `testParagraphConvertedToList_rowIsListWithoutFB`: the same typing, but only the
//  per-edit poll and no close, asserting the row is already a bullet list (the update now carries the editor's type).
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

        // The user puts the caret at the very start of the paragraph, types "- " (Milkdown turns the paragraph into a
        // bullet list) and a word, then closes at once.
        try await placeCursorAtStartOfParagraph(helper, startingWith: "convert me please.")
        try await Task.sleep(nanoseconds: 200_000_000)
        try typeViaNSEvents("- ", window: window)
        try await Task.sleep(nanoseconds: 300_000_000)
        try typeViaNSEvents(Self.typedWord, window: window)

        // Wait on what is true, not on a fixed sleep: the editor SERIALIZES a bullet list as `* item` (Milkdown's marker),
        // never `- item`, so the converted paragraph is recognised by its SHAPE -- a list-marker line starting with the
        // typed word -- (Phase 5 B4: the page reports the conversion itself; the probe no longer asks for it to be pending.)
        // (The first version of this
        // probe looked for the literal "- " the user typed and failed on the editor's own `* ` output.)
        let typedLine = "(?m)^[ \\t]*[-*+][ \\t]+\(Self.typedWord)"
        let observed = try await SwitchFlushTestSupport.waitForPendingEdit(helper) { markdown in
            markdown.range(of: typedLine, options: .regularExpression) != nil
        }
        XCTAssertTrue(
            observed.contentMatches,
            "the paragraph never became a bullet list starting with the typed word; editor content=\(observed.content)")
        guard observed.isReady else { return }

        // Close: the save sequence (F, fresh fetch, FB, barrier), as `LifecycleEntry.run(.close)` runs it before `perform`.
        guard let token = SwitchFlushTestSupport.arm(editorState, kind: .close) else { return XCTFail("could not arm the close token") }
        let result = await SwitchFlushTestSupport.flush(editorState, token: token, webView: helper.webView)
        XCTAssertEqual(result.outcome, .flushed)
        // U-C2, as changed by t-4eb7bfa9: after a LIST edit FB has nothing to rebuild (`.unchanged`): the stored row reads
        // `* word...` (the per-block text is Milkdown's own serializer's piece) exactly as the whole-document fetch does. Before
        // t-4eb7bfa9 the per-block converter wrote `- word...`, the check found the rows different and FB rebuilt the table.
        XCTAssertEqual(
            result.fbSettledOutcome, .unchanged,
            "a list conversion alone must close with FB .unchanged (the barrier waited for the check); status \(result.fbStatus)")

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
        _ = await sync.flushForDatabaseRebuild()
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

    // U-B2 (t-94369a83 Phase 3a-2, Step 1; plan-v2 U-B2). The per-edit path ALONE stores the conversion correctly: no
    // close, no FB. Before Step 1 the poll left the row a paragraph holding the list's text (the update carried no
    // type), so a reopen without the close-time rebuild showed the list twice. This is the test that proves Step 1.
    @MainActor
    func testParagraphConvertedToList_rowIsListWithoutFB() async throws {
        let stack = try await makeStack()
        let (helper, db, pid, sync) = (stack.helper, stack.db, stack.pid, stack.sync)
        guard let window = hostWindow else { throw XCTSkip("no host window") }

        let rowsBefore = try TestFixtureFactory.fetchBlocks(from: db)
        let original = try XCTUnwrap(rowsBefore.first { $0.markdownFragment.contains("convert me please.") })
        XCTAssertEqual(original.blockType, .paragraph)

        try await placeCursorAtStartOfParagraph(helper, startingWith: "convert me please.")
        try await Task.sleep(nanoseconds: 200_000_000)
        try typeViaNSEvents("- ", window: window)
        try await Task.sleep(nanoseconds: 300_000_000)
        try typeViaNSEvents(Self.typedWord, window: window)

        let typedLine = "(?m)^[ \\t]*[-*+][ \\t]+\(Self.typedWord)"
        let observed = try await SwitchFlushTestSupport.waitForPendingEdit(helper) { markdown in
            markdown.range(of: typedLine, options: .regularExpression) != nil
        }
        XCTAssertTrue(
            observed.contentMatches,
            "the paragraph never became a bullet list starting with the typed word; editor content=\(observed.content)")
        guard observed.isReady else { return }

        // The poll alone (no close): the update lands in the table. Wait on the table, not on a fixed sleep.
        _ = await sync.flushForDatabaseRebuild()
        var rows = try TestFixtureFactory.fetchBlocks(from: db).sorted { $0.sortOrder < $1.sortOrder }
        let end = Date().addingTimeInterval(5)
        while !rows.contains(where: { $0.markdownFragment.contains(Self.typedWord) }) && Date() < end {
            try await Task.sleep(nanoseconds: 100_000_000)
            rows = try TestFixtureFactory.fetchBlocks(from: db).sorted { $0.sortOrder < $1.sortOrder }
        }

        let withWord = rows.filter { $0.markdownFragment.contains(Self.typedWord) }
        let described = withWord.map { "\($0.blockType.rawValue):\($0.markdownFragment)" }
        XCTAssertEqual(withWord.count, 1, "exactly ONE row carries the converted item; found \(withWord.count): \(described)")
        XCTAssertEqual(withWord.first?.id, original.id, "the converted row keeps the original paragraph's id")
        XCTAssertEqual(
            withWord.first?.blockType, .bulletList,
            "the converted paragraph is stored as a bullet list by the poll alone, got \(String(describing: withWord.first?.blockType))")
        XCTAssertEqual(rows.count, rowsBefore.count, "no row was added or removed: \(rows.map(\.markdownFragment))")

        // What a reopen reads: the stored rows must align with the editor nodes a re-parse of their Markdown gives, or
        // `alignTopLevelIds` withholds the id and the next poll inserts the list a second time.
        let storedPairs = BlockParser.alignmentPairs(rows)
        XCTAssertEqual(
            storedPairs.first { $0.id == original.id }?.meta.blockType, "bullet_list",
            "the original paragraph's id must be listed with meta bullet_list, so it is not withheld on reopen")
        let reparsedPairs = BlockParser.alignmentPairs(BlockParser.parse(markdown: BlockParser.assembleMarkdown(from: rows), projectId: pid))
        XCTAssertEqual(
            storedPairs.map(\.meta.blockType), reparsedPairs.map(\.meta.blockType),
            "the stored rows and a re-parse of them must agree on every top-level node's type")
    }

    // U-C2b (t-94369a83 Phase 3a-2, plan-v2 U-C2b; amendment A2): the test that the skip actually FIRES. A session that
    // only changed plain paragraph and heading text -- a sentence added at the end of a paragraph, a word added to a
    // heading -- closes with FB `.unchanged`: nothing written, no epoch bump, no id replaced.
    //
    // STOP RULE (A2): if FB does not reach `.unchanged` here, stop and report exactly which compared fields differ (the
    // failure message prints them); NEVER loosen `LifecycleWholeDocumentWrite.rowsMatch` to make this pass. The typed
    // text is plain letters, spaces and a full stop only: no `_`, `*`, `[`, backslash or apostrophe, so the differences
    // between the editor's two serializers (plan-v2 section 0) cannot cause a false failure.
    @MainActor
    func testPlainProseSession_closeReachesUnchanged() async throws {
        let stack = try await makeStack()
        let (helper, db, pid, editorState) = (stack.helper, stack.db, stack.pid, stack.editorState)
        guard let window = hostWindow else { throw XCTSkip("no host window") }

        let rowsBefore = try TestFixtureFactory.fetchBlocks(from: db)
        let idsBefore = rowsBefore.map(\.id)
        let epochBefore = try db.currentBlockWriteEpoch(projectId: pid)

        // A sentence at the end of a paragraph, then a word at the end of a heading.
        try await placeCursorAtEnd(helper, tag: "p", startingWith: "four five six.")
        try await Task.sleep(nanoseconds: 200_000_000)
        try typeViaNSEvents(" and more plain words here.", window: window)
        try await Task.sleep(nanoseconds: 300_000_000)
        try await placeCursorAtEnd(helper, tag: "h1", startingWith: "Alpha")
        try await Task.sleep(nanoseconds: 200_000_000)
        try typeViaNSEvents(" renamed", window: window)

        let observed = try await SwitchFlushTestSupport.waitForPendingEdit(helper) { markdown in
            markdown.contains("four five six. and more plain words here.") && markdown.contains("# Alpha renamed")
        }
        XCTAssertTrue(
            observed.contentMatches,
            "the editor never showed both plain-text edits; editor content=\(observed.content)")
        guard observed.isReady else { return }

        // Close: the save sequence (F, fresh fetch, FB, barrier), as `LifecycleEntry.run(.close)` runs it before `perform`.
        guard let token = SwitchFlushTestSupport.arm(editorState, kind: .close) else { return XCTFail("could not arm the close token") }
        let result = await SwitchFlushTestSupport.flush(editorState, token: token, webView: helper.webView)
        XCTAssertEqual(result.outcome, .flushed)

        let rowsAfter = try TestFixtureFactory.fetchBlocks(from: db)
        let sortedAfter = BlockParser.assemblySorted(rowsAfter)
        let fetched = result.fetchedContent ?? ""
        let wouldWrite = ProjectDatabase.preparedRowsForWholeReplace(
            existing: sortedAfter,
            parsed: BlockParser.parse(
                markdown: fetched, projectId: pid, existingSectionMetadata: nil,
                notesHeaderName: try? db.fetchNotesHeadingTitle(projectId: pid)))
        let difference = LifecycleWholeDocumentWrite.firstDifference(stored: sortedAfter, wouldWrite: wouldWrite) ?? "no compared field differs"
        XCTAssertEqual(
            result.fbSettledOutcome, .unchanged,
            "A2 STOP RULE: a plain-prose session must close with FB .unchanged; status \(result.fbStatus). "
                + "Near tie: \(LifecycleWholeDocumentWrite.hasNearTie(sortedAfter)). Differing compared fields: \(difference). "
                + "Fetched: \(fetched.debugDescription)")

        // The table holds the typed text, and nothing else moved: no row added, removed or re-keyed, no epoch bump.
        XCTAssertEqual(rowsAfter.map(\.id), idsBefore, "no id was replaced (FB rebuilt nothing)")
        XCTAssertTrue(
            rowsAfter.contains { $0.markdownFragment.contains("four five six. and more plain words here.") },
            "the typed sentence is in the table: \(rowsAfter.map(\.markdownFragment))")
        XCTAssertTrue(
            rowsAfter.contains { $0.blockType == .heading && $0.markdownFragment == "# Alpha renamed" },
            "the heading edit is in the table: \(rowsAfter.map(\.markdownFragment))")
        XCTAssertEqual(try db.currentBlockWriteEpoch(projectId: pid), epochBefore, "an unchanged FB (and F) bump no epoch")
    }

    // t-4eb7bfa9 (Rich Text per-block save matches the whole-document save): the shapes the old per-block converter wrote
    // differently from the whole-document serializer. A session that types a quote of two paragraphs, plain text holding
    // `_` and `*`, a line break, a tight list and a list item of two paragraphs must leave rows the close finds nothing to
    // rebuild in: FB `.unchanged`.
    //
    // How the shapes get in. The quote, the line break, the tight list and the list item are TYPED with real NSEvents (Return is
    // keyCode 36, the line break is Shift-Return). The symbol words are NOT typed: Milkdown's input rules would make a typed
    // `__init__` bold and `*x*` italic. They go in as plain text through the page (`insertAtCursor`, a plain transaction that
    // runs no input rule), and the second paragraph of the list item is a pasted plain-text paragraph (the editor has no key
    // for a second paragraph in an item; a pasted one is how a user gets it).
    //
    // BEFORE the close, each stored row must already hold the intended shape, and no row may have been added, removed or
    // re-keyed by the close; only then is `.unchanged` asserted (the order the plain-prose test uses).
    //
    // STOP RULE (as for the plain-prose test): if the close does not reach `.unchanged`, report which compared field differs
    // (the failure message prints it); NEVER loosen `LifecycleWholeDocumentWrite.rowsMatch` to make this pass.
    @MainActor
    func testRichTextShapes_closeReachesUnchanged() async throws {
        let stack = try await makeStack()
        let (helper, db, pid, sync, editorState) = (stack.helper, stack.db, stack.pid, stack.sync, stack.editorState)
        guard let window = hostWindow else { throw XCTSkip("no host window") }

        let rowsBefore = try TestFixtureFactory.fetchBlocks(from: db)
        let idsBefore = Set(rowsBefore.map(\.id))

        // From the end of "convert me please.": a new paragraph, then the quote. "> " turns the empty paragraph into a quote; the
        // second Return inside it leaves an empty paragraph there, and the third lifts that paragraph out of the quote.
        try await placeCursorAtEnd(helper, tag: "p", startingWith: "convert me please.")
        try await Task.sleep(nanoseconds: 200_000_000)
        try pressReturn(window: window)
        try await Task.sleep(nanoseconds: 200_000_000)
        try typeViaNSEvents("> ", window: window)
        try await Task.sleep(nanoseconds: 300_000_000)
        try typeViaNSEvents("first", window: window)
        try pressReturn(window: window)
        try typeViaNSEvents("second", window: window)
        try pressReturn(window: window)
        try pressReturn(window: window)
        try await Task.sleep(nanoseconds: 300_000_000)

        // Three paragraphs of plain text with the characters the serializer escapes (or must not escape).
        for word in ["snake_case_name", "__init__", "2 * 3 * 4"] {
            try await insertPlainText(word, helper: helper)
            try pressReturn(window: window)
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        // A tight list of two items, left with two Returns (the second turns the empty item back into a paragraph).
        try typeViaNSEvents("- ", window: window)
        try await Task.sleep(nanoseconds: 300_000_000)
        try typeViaNSEvents("a", window: window)
        try pressReturn(window: window)
        try typeViaNSEvents("b", window: window)
        try pressReturn(window: window)
        try pressReturn(window: window)
        try await Task.sleep(nanoseconds: 300_000_000)

        // A line break inside a paragraph, and a paragraph after it to start the last list.
        try typeViaNSEvents("line one", window: window)
        try pressShiftReturn(window: window)
        try typeViaNSEvents("line two", window: window)
        try pressReturn(window: window)
        try await Task.sleep(nanoseconds: 300_000_000)

        // A list whose first item holds two paragraphs, then a second item.
        try typeViaNSEvents("- ", window: window)
        try await Task.sleep(nanoseconds: 300_000_000)
        try await pastePlainText("one\n\ntwo", helper: helper)
        try await Task.sleep(nanoseconds: 300_000_000)
        try pressReturn(window: window)
        try typeViaNSEvents("three", window: window)

        let observed = try await SwitchFlushTestSupport.waitForPendingEdit(helper, timeout: 10) { markdown in
            markdown.contains("> first\n>\n> second") && markdown.contains("snake_case_name") && markdown.contains("line one\\\nline two")
                && markdown.contains("* one\n\n  two") && markdown.contains("three")
        }
        XCTAssertTrue(observed.contentMatches, "the editor never showed all the shapes; editor content=\(observed.content.debugDescription)")
        guard observed.isReady else { return }

        // The per-edit path alone (no close): wait on the table, not on a fixed sleep, for the seven new rows.
        let expected: [(kind: BlockType, fragment: String)] = [
            (.blockquote, "> first\n>\n> second"),
            (.paragraph, "snake_case_name"),
            (.paragraph, "\\_\\_init\\_\\_"),
            (.paragraph, "2 * 3 * 4"),
            (.bulletList, "* a\n* b"),
            (.paragraph, "line one\\\nline two"),
            (.bulletList, "* one\n\n  two\n* three")
        ]
        _ = await sync.flushForDatabaseRebuild()
        var stored = BlockParser.assemblySorted(try TestFixtureFactory.fetchBlocks(from: db))
        let end = Date().addingTimeInterval(8)
        while stored.count < rowsBefore.count + expected.count && Date() < end {
            try await Task.sleep(nanoseconds: 150_000_000)
            _ = await sync.flushForDatabaseRebuild()
            stored = BlockParser.assemblySorted(try TestFixtureFactory.fetchBlocks(from: db))
        }
        let described = stored.map { "\($0.blockType.rawValue):\($0.markdownFragment.debugDescription)" }
        XCTAssertEqual(stored.count, rowsBefore.count + expected.count, "the table must hold the four old rows and the seven new ones: \(described)")
        XCTAssertTrue(idsBefore.isSubset(of: Set(stored.map(\.id))), "the four old rows keep their ids: \(described)")
        let anchor = try XCTUnwrap(stored.firstIndex { $0.markdownFragment.contains("convert me please.") }, "the anchor row is gone: \(described)")
        let newRows = Array(stored.dropFirst(anchor + 1).prefix(expected.count))
        XCTAssertEqual(newRows.map { $0.blockType }, expected.map { $0.kind }, "the new rows' types, in order: \(described)")
        XCTAssertEqual(
            newRows.map { $0.markdownFragment.trimmingCharacters(in: .whitespacesAndNewlines) }, expected.map { $0.fragment },
            "each stored row must hold the intended shape (the whole-document serializer's piece): \(described)")
        // The stored text is what a close writes for the same Markdown (t-4eb7bfa9, step 5): derived from the fragment, under the row's type.
        for row in newRows {
            let fragment = row.markdownFragment.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(
                row.textContent.trimmingCharacters(in: .whitespacesAndNewlines),
                BlockParser.extractTextContent(from: fragment, blockType: row.blockType),
                "stored text of \(fragment.debugDescription) must be what the close derives from it")
        }
        XCTAssertEqual(newRows.first?.textContent, "first\n\nsecond", "the quote's two paragraphs stay apart in the stored text")
        XCTAssertEqual(newRows.dropFirst(2).first?.textContent, "__init__", "the escapes are not part of the stored text")

        // Close: the save sequence (F, fresh fetch, FB, barrier). Nothing may be rebuilt: same rows, same ids, no epoch bump.
        let idsAfterEdit = stored.map(\.id)
        let epochBeforeClose = try db.currentBlockWriteEpoch(projectId: pid)
        guard let token = SwitchFlushTestSupport.arm(editorState, kind: .close) else { return XCTFail("could not arm the close token") }
        let result = await SwitchFlushTestSupport.flush(editorState, token: token, webView: helper.webView)
        XCTAssertEqual(result.outcome, .flushed)

        let rowsAfter = try TestFixtureFactory.fetchBlocks(from: db)
        let sortedAfter = BlockParser.assemblySorted(rowsAfter)
        let fetched = result.fetchedContent ?? ""
        let wouldWrite = ProjectDatabase.preparedRowsForWholeReplace(
            existing: sortedAfter,
            parsed: BlockParser.parse(
                markdown: fetched, projectId: pid, existingSectionMetadata: nil,
                notesHeaderName: try? db.fetchNotesHeadingTitle(projectId: pid)))
        let difference = LifecycleWholeDocumentWrite.firstDifference(stored: sortedAfter, wouldWrite: wouldWrite) ?? "no compared field differs"
        XCTAssertEqual(
            result.fbSettledOutcome, .unchanged,
            "STOP RULE: a session of these shapes must close with FB .unchanged; status \(result.fbStatus). "
                + "Near tie: \(LifecycleWholeDocumentWrite.hasNearTie(sortedAfter)). Differing compared fields: \(difference). "
                + "Fetched: \(fetched.debugDescription)")
        XCTAssertEqual(sortedAfter.map(\.id), idsAfterEdit, "no row was added, removed or re-keyed by the close")
        XCTAssertEqual(try db.currentBlockWriteEpoch(projectId: pid), epochBeforeClose, "an unchanged FB (and F) bump no epoch")
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

    /// Collapses the DOM selection to the END of the first `tag` element whose text starts with `text`.
    ///
    /// The caret goes after the LAST non-empty text node found anywhere inside the element (a tree walk), not after
    /// `element.lastChild`: a Rich Text heading is `<h1 data-placeholder="# "><span>Alpha</span></h1>` (its content
    /// lives in a `<span>`, `heading-nodeview-plugin.ts`), so the heading's lastChild is that span, not a text node
    /// (the first version of this helper answered "no-text-node" for the h1, while a paragraph's lastChild is the
    /// text itself). Text inside a non-editable island (a widget or decoration) is skipped,
    /// since the caret cannot live there. When no text node is found the diagnostic carries the element's markup, so a
    /// failure says what the DOM looked like.
    @MainActor
    private func placeCursorAtEnd(_ helper: EditorTestHelper, tag: String, startingWith text: String) async throws {
        let escaped = text.replacingOccurrences(of: "'", with: "\\'")
        let result = try await helper.webView.evaluateJavaScript(
            """
            (() => {
                const pm = document.querySelector('.ProseMirror');
                if (!pm) return 'no-prosemirror-root';
                const target = Array.from(pm.querySelectorAll('\(tag)')).find(el => (el.textContent || '').startsWith('\(escaped)'));
                if (!target) return 'no-element';
                const walker = document.createTreeWalker(target, NodeFilter.SHOW_TEXT);
                let textNode = null;
                while (walker.nextNode()) {
                    const node = walker.currentNode;
                    const island = node.parentElement ? node.parentElement.closest('[contenteditable="false"]') : null;
                    if (node.data.length > 0 && !(island && target.contains(island))) textNode = node;
                }
                if (!textNode) return 'no-text-node; markup=' + target.outerHTML.slice(0, 300);
                pm.focus();
                const range = document.createRange();
                range.setStart(textNode, textNode.data.length);
                range.collapse(true);
                const sel = window.getSelection();
                sel.removeAllRanges();
                sel.addRange(range);
                return 'ok';
            })()
            """
        ) as? String
        XCTAssertEqual(result, "ok", "failed to place the caret at the end of the \(tag) (diagnostic: \(String(describing: result)))")
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

    /// One real key press (keyDown, keyUp) with the key code of that key, the characters it types and the modifiers held.
    /// `typeViaNSEvents` above sends key code 0 for every character, which is enough for letters, space and punctuation but is
    /// not the Return key: Return needs key code 36 and the "\r" character (as in `QuitFlushDuplicateInsertTests.pressEnter`).
    @MainActor
    private func pressKey(_ keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = [], window: NSWindow) throws {
        let now = ProcessInfo.processInfo.systemUptime
        guard
            let down = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: now, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode
            ),
            let keyUp = NSEvent.keyEvent(
                with: .keyUp, location: .zero, modifierFlags: modifiers,
                timestamp: now, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode
            )
        else {
            throw NSError(
                domain: "list-conversion-test", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "could not build NSEvent for key code \(keyCode)"]
            )
        }
        window.sendEvent(down)
        window.sendEvent(keyUp)
    }

    /// Return: splits the block, or leaves a quote or list when pressed in an empty block of one.
    @MainActor
    private func pressReturn(window: NSWindow) throws {
        try pressKey(36, characters: "\r", window: window)
    }

    /// Shift-Return: the line break (Milkdown's hard break) inside a paragraph.
    @MainActor
    private func pressShiftReturn(window: NSWindow) throws {
        try pressKey(36, characters: "\r", modifiers: .shift, window: window)
    }

    /// Puts `text` into the document at the caret as PLAIN text, through the page's own `insertAtCursor` (a plain transaction:
    /// it runs no input rule, so `__init__` stays text instead of turning bold the way typing it would).
    @MainActor
    private func insertPlainText(_ text: String, helper: EditorTestHelper) async throws {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let result = try await helper.webView.evaluateJavaScript(
            "window.FinalFinal.insertAtCursor('\(escaped)'); 'ok'"
        ) as? String
        XCTAssertEqual(result, "ok", "failed to insert plain text (diagnostic: \(String(describing: result)))")
    }

    /// Pastes `text` as plain text: a real DOM `ClipboardEvent('paste')` on the editable root, the event the editor's own paste
    /// handling reads (same technique as `PasteAboveHeadingOrderBugTests.dispatchSyntheticPaste`).
    @MainActor
    private func pastePlainText(_ text: String, helper: EditorTestHelper) async throws {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        let result = try await helper.webView.evaluateJavaScript(
            """
            (() => {
                const pm = document.querySelector('.ProseMirror');
                if (!pm) return 'no-prosemirror-root';
                const dt = new DataTransfer();
                dt.setData('text/plain', '\(escaped)');
                pm.dispatchEvent(new ClipboardEvent('paste', { bubbles: true, cancelable: true, clipboardData: dt }));
                return 'ok';
            })()
            """
        ) as? String
        XCTAssertEqual(result, "ok", "failed to dispatch the paste (diagnostic: \(String(describing: result)))")
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
