//
//  ReorderEditorFirstBridgeTests.swift
//  final finalTests
//
//  Tier 2 (t-0b70d1e9, the plan's two bridge tests): the editor-first drag-reorder against the REAL Milkdown bundle in a real WKWebView.
//  The scripted rig of EditorFirstReorderTests answers the editor's calls with Swift code, so it cannot tell whether the script Swift
//  really builds reaches a function that exists, takes those arguments and moves the document; and jsdom (the web tests) has no layout,
//  so it cannot tell where the caret ends up on the screen. Both are proven here.
//
//  The script is built exactly as production builds it: `StructuralUndoController.editorFirstScript(function:
//  "reorderSectionsEditorFirst", ..., extraArguments: [orderLiteral])`, with the order literal `jsLiteral` makes of `{id, level?}`
//  entries; the reply is decoded with the real `EditorFirstReorderReply`.
//
//  Uses XCTest (not Swift Testing) because WKWebView requires a run loop, like HeadingManagedBlockIdSyncTests.
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import XCTest
import WebKit
@testable import final_final

final class ReorderEditorFirstBridgeTests: XCTestCase {

    /// Keeps the web view on screen: the editor's layout (and requestAnimationFrame) only runs in a window that is ordered front.
    private var hostWindow: NSWindow?

    @MainActor
    override func tearDown() async throws {
        hostWindow?.orderOut(nil)
        hostWindow = nil
    }

    private struct Stack {
        let helper: EditorTestHelper
        let db: ProjectDatabase
        let pid: String
        let controller: StructuralUndoController
    }

    /// A real editor holding the database's document with the database's block ids (as the app pushes it when a project opens).
    @MainActor
    private func makeStack(content: String) async throws -> Stack {
        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let helper = EditorTestHelper(editorType: .milkdown)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = helper.webView
        window.orderFront(nil)
        hostWindow = window
        try await helper.loadAndWaitForReady(timeout: 15)

        let sync = BlockSyncService()
        sync.configure(database: db, projectId: pid, webView: helper.webView)
        let controller = StructuralUndoController()
        let pushed = try XCTUnwrap(controller.fetchFullBlocksWithIds(db: db, pid: pid), "the document could not be read from the database")
        await sync.setContentWithBlockIds(
            markdown: pushed.markdown, blockIds: pushed.blockIds, imageMeta: pushed.imageMeta,
            cursorBoundary: pushed.bibBoundaryIndex, cursorBoundaryEnd: pushed.bibBoundaryEndIndex,
            expectedBlocks: pushed.expectedBlocks, managedBlockIds: pushed.managedBlockIds)
        try await Task.sleep(nanoseconds: 500_000_000)
        return Stack(helper: helper, db: db, pid: pid, controller: controller)
    }

    private func headingId(_ title: String, in stack: Stack) throws -> String {
        let rows = try stack.db.fetchBlocks(projectId: stack.pid)
        return try XCTUnwrap(rows.first { $0.blockType == .heading && $0.textContent == title }, "no heading '\(title)'").id
    }

    /// Builds the click's script the way production does and evaluates it in the page: the section titled `root` is dragged and the
    /// document is to end up with the headings in `order`.
    @MainActor
    private func click(_ stack: Stack, root: String, order titles: [String]) async throws -> EditorFirstReorderReply {
        // The entries are the production type, the one the click itself encodes (`ReorderOrderEntry`).
        let entries = try titles.map { ReorderOrderEntry(id: try headingId($0, in: stack), level: nil) }
        let orderLiteral = try XCTUnwrap(StructuralUndoController.jsLiteral(entries))
        let built = try XCTUnwrap(stack.controller.editorFirstScript(
            function: "reorderSectionsEditorFirst", opId: UUID(), rootId: try headingId(root, in: stack),
            database: stack.db, projectId: stack.pid, logName: "reorder", extraArguments: [orderLiteral]))
        let json = try await stack.helper.webView.evaluateJavaScript(built.script) as? String
        let data = try XCTUnwrap(json?.data(using: .utf8), "the editor answered \(String(describing: json)) instead of a JSON reply")
        return try JSONDecoder().decode(EditorFirstReorderReply.self, from: data)
    }

    // MARK: - The script Swift builds reaches the real editor

    private static let threeSections = """
    # Alpha

    Alpha body.

    # Bravo

    Bravo body.

    # Charlie

    Charlie body.
    """

    // The bridge test of plan decision 2 (A2): the real bundle has `reorderSectionsEditorFirst`, takes the arguments Swift sends, answers
    // a reply the real decoder reads, and the document is in the new order, each body still under its heading.
    @MainActor
    func testSwiftBuiltScriptReordersInRealEditor() async throws {
        let stack = try await makeStack(content: Self.threeSections)

        let reply = try await click(stack, root: "Alpha", order: ["Bravo", "Alpha", "Charlie"])

        XCTAssertTrue(reply.succeeded, "the editor refused the reorder: \(reply.reason ?? "no reason")")
        XCTAssertNil(reply.reason)
        XCTAssertEqual(reply.skippedIds, [], "the editor held no node for some ids")
        XCTAssertGreaterThan(reply.moved, 0, "nothing moved")
        let content = try await stack.helper.getContent()
        let lines = content.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        XCTAssertEqual(
            lines, ["# Bravo", "Bravo body.", "# Alpha", "Alpha body.", "# Charlie", "Charlie body."],
            "the document is not in the new order: \(content)")
    }

    // MARK: - Notes and Bibliography stay last

    /// Three chapters, a footnote, a Notes section and a bibliography (the end marker flags `# References` and its entry).
    private static let managedDocument = """
    # Alpha

    Alpha body[^1].

    # Bravo

    Bravo body.

    # Charlie

    Charlie body.

    # Notes

    [^1]: The footnote text.

    # References

    Smith, J. (2023). A cited source.

    <!-- ::auto-bibliography-end:: -->
    """

    /// The heading lines of the editor's Markdown, in order.
    private func headingLines(_ content: String) -> [String] {
        content.split(separator: "\n").map(String.init).filter { $0.hasPrefix("# ") }
    }

    // W4 (EVERYDAY): a book with a footnote and a bibliography. The click names every section in its order, Notes and Bibliography last,
    // as production does. Every id has a node in the editor (nothing is skipped: a skipped id would cost a sidebar card), the last chapter
    // goes to the top, and Notes then the Bibliography are still the last two sections of the document.
    @MainActor
    func testFootnoteAndBibliographyStayLastAndNothingIsSkipped() async throws {
        let stack = try await makeStack(content: Self.managedDocument)

        let reply = try await click(stack, root: "Charlie", order: ["Charlie", "Alpha", "Bravo", "Notes", "References"])

        XCTAssertTrue(reply.succeeded, "the editor refused the reorder: \(reply.reason ?? "no reason")")
        XCTAssertEqual(reply.skippedIds, [], "the editor held no node for some of the sections, e.g. the Notes or the Bibliography heading")
        let content = try await stack.helper.getContent()
        XCTAssertEqual(
            headingLines(content), ["# Charlie", "# Alpha", "# Bravo", "# Notes", "# References"],
            "the sections are not in the new order, or Notes / Bibliography left the end: \(content)")
    }

    // C1's editor half (EVERYDAY): the plan was made before the Notes section existed in the sidebar's list (a footnote typed a moment
    // ago), so its order names only the chapters. The editor works out where its own Notes / Bibliography region starts from the live
    // document (the managed ids Swift sends) and never lets the last chapter's group reach into it: the Notes and the Bibliography do
    // not travel to the top with Charlie.
    @MainActor
    func testNotesAndBibliographyStayLastWhenThePlanDoesNotListThem() async throws {
        let stack = try await makeStack(content: Self.managedDocument)

        let reply = try await click(stack, root: "Charlie", order: ["Charlie", "Alpha", "Bravo"])

        XCTAssertTrue(reply.succeeded, "the editor refused the reorder: \(reply.reason ?? "no reason")")
        XCTAssertEqual(reply.skippedIds, [])
        let content = try await stack.helper.getContent()
        XCTAssertEqual(
            headingLines(content), ["# Charlie", "# Alpha", "# Bravo", "# Notes", "# References"],
            "the Notes or the Bibliography travelled with the last chapter: \(content)")
    }

    // MARK: - The caret keeps its place on the screen

    /// Four chapters; Delta is long. The caret sits in Bravo's first paragraph, near the top of the window.
    private static func longDocument() -> (markdown: String, caretLine: Int) {
        func paragraphs(_ name: String, _ count: Int) -> [String] {
            (1...count).map { "\(name) paragraph \($0). " + String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 6) }
        }
        let blocks = ["# Alpha"] + paragraphs("Alpha", 1)
            + ["# Bravo", "Bravo caret paragraph. The caret is in this one."] + paragraphs("Bravo", 3)
            + ["# Charlie"] + paragraphs("Charlie", 10)
            + ["# Delta"] + paragraphs("Delta", 12)
        let markdown = blocks.joined(separator: "\n\n")
        let caretLine = (markdown.components(separatedBy: "\n").firstIndex { $0.hasPrefix("Bravo caret paragraph.") } ?? 0) + 1
        return (markdown, caretLine)
    }

    private struct CaretReading: Decodable {
        let top: Double
        let scrollY: Double
        let innerHeight: Double
        let text: String
    }

    /// Where the block holding the caret is on the screen (the top edge of its box in viewport coordinates) and how far the page is scrolled.
    @MainActor
    private func readCaret(_ stack: Stack) async throws -> CaretReading {
        let json = try await stack.helper.webView.evaluateJavaScript(
            """
            (function () {
              const sel = window.getSelection();
              if (!sel || sel.rangeCount === 0) return null;
              const node = sel.focusNode;
              const el = node && node.nodeType === 1 ? node : (node ? node.parentElement : null);
              const block = el ? el.closest('p, h1, h2, h3, h4, h5, h6, li, blockquote') : null;
              if (!block) return null;
              return JSON.stringify({
                top: block.getBoundingClientRect().top, scrollY: window.scrollY,
                innerHeight: window.innerHeight, text: block.textContent.slice(0, 40)
              });
            })()
            """) as? String
        let data = try XCTUnwrap(json?.data(using: .utf8), "the page has no caret inside a text block")
        return try JSONDecoder().decode(CaretReading.self, from: data)
    }

    // The plan's viewport guarantee (b): a section from below the caret is dragged ABOVE it, which adds the section's whole height above
    // the caret. The editor scrolls the page by that height, so the caret's line stays exactly where it was on the screen. jsdom has no
    // layout, so this is only provable in a real web view.
    @MainActor
    func testCaretLineKeepsScreenY() async throws {
        let document = Self.longDocument()
        let stack = try await makeStack(content: document.markdown)
        _ = try await stack.helper.webView.evaluateJavaScript(
            "window.FinalFinal.setCursorPosition({line: \(document.caretLine), column: 3})")
        try await Task.sleep(nanoseconds: 500_000_000)
        let before = try await readCaret(stack)
        XCTAssertTrue(before.text.hasPrefix("Bravo caret paragraph"), "the caret is not in Bravo's paragraph: '\(before.text)'")
        XCTAssertTrue(before.top >= 0 && before.top < before.innerHeight, "precondition: the caret's line must be on the screen (top \(before.top))")

        let reply = try await click(stack, root: "Delta", order: ["Delta", "Alpha", "Bravo", "Charlie"])
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(reply.succeeded, "the editor refused the reorder: \(reply.reason ?? "no reason")")
        let after = try await readCaret(stack)
        XCTAssertTrue(after.text.hasPrefix("Bravo caret paragraph"), "the caret left Bravo's paragraph: '\(after.text)'")
        XCTAssertGreaterThan(
            after.scrollY - before.scrollY, 100,
            "the page was not scrolled: the moved section should have pushed the caret down by its height "
                + "(scrollY \(before.scrollY) -> \(after.scrollY))")
        XCTAssertLessThanOrEqual(
            abs(after.top - before.top), 2, "the caret's line moved on the screen: top \(before.top) -> \(after.top)")
    }
}
