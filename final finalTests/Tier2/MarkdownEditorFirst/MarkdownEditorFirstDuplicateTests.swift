//
//  MarkdownEditorFirstDuplicateTests.swift
//  final finalTests
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), slice 3, round C2: the Markdown editor-first Duplicate Section click
//  (`StructuralUndoController.performMarkdownEditorFirstDuplicate`, StructuralUndoController+MarkdownEditorFirstDuplicate.swift) against
//  the REAL CodeMirror page, a real database and the real writer (`MarkdownClickRig`). This file holds the page-and-rows tests; the
//  Cmd-Z / Cmd-Shift-Z tests are in MarkdownEditorFirstDuplicateTests+Undo.swift, the commands pressed at once after a Duplicate in
//  +Chain.swift, the settle / stale-rebuild / failure tests and the tests of the old body taken (the switch off, a zoom) in +Settle.swift,
//  the held-hold / document-shape tests in +Hold.swift. Needs `cd web && pnpm build` first.
//
//  EVERY wait on a command, a job, a hold or a settle in these files is BOUNDED (`bounded`, `finish`, `settleAll`, `performDuplicate`
//  ... below): a bug shows as a red "stuck for N s: ..." test, not as a stuck run. A job-body hold (`holdJobs`, `holdReinserts`) is a
//  semaphore, one `release()` per job that reaches it; the tearDown frees whatever a test left.
//
//  Break patches (1 to 5 changed lines INSIDE the new production code that must make the test fail) are in
//  docs/architecture/write-queue-plan/phase4b-markdown/slice3-duplicate/break-patches/swift-<TESTID>.patch. The failure each shows:
//
//   U1   testDuplicateShowsTheCopyAtOnceAndTheRowsMatchThePage
//        BREAK: pass `copies: []`/nil to the job.   FAILS: "row id != marker"
//   U2   testTypingWhileTheDuplicateJobIsHeldIsKeptAndSaved
//        BREAK: release the hold at the click.   FAILS: "typing saved while the job was held"
//   U3   testTypingJustBeforeTheClickIsSavedWithIt
//        BREAK: skip `prepareStructuralClick`.   FAILS: "typing lost: zq7 not in the rows before the job ran"
//   U4   testTheCopysCardTargetIsTheCopyWhileTheJobIsHeldAndAfter   (in +Settle.swift)
//        BREAK: `new = source` in the minted pairs.   FAILS: "card target is not the copy's heading"
//   U9   testDuplicatingTheLastChapterBeforeNotesAndBibliographyKeepsBoth   (in +Hold.swift)
//        BREAK: ignore stopLine (page side).   see the patch
//   U10  testSectionBreakRootCopyHasNoSuffix   (in +Hold.swift)
//        BREAK: always suffix.   FAILS: "the section break got a ' copy' suffix"
//   U12  testTheSidebarShowsTheCopyBeforeItsRowsExist...   (in +Settle.swift)
//        BREAK: skip the overlay call.   FAILS: "card missing"
//   U13  testWithTheSwitchOffPerformSectionDuplicateTakesTheOldBody   CONTROL   (in +Settle.swift)
//   U17  testDuplicatingAChapterWithSubsectionsGivesEveryCopiedLeader...   (in +Hold.swift)
//        BREAK: rewrite only the root marker.   FAILS: "copied leaders carry"
//   U24  testWhileZoomed...   (in +Settle.swift)
//        BREAK: drop `zoomedSectionId == nil`.   FAILS: "markdownStructuralDuplicate called while zoomed"
//

import Foundation
import XCTest
@testable import final_final

/// One `<!-- @sid:ID -->` marker on a page line: the id and the rest of that line.
struct PageMarker: Equatable {
    let id: String
    let line: String
}

/// Counts the notifications of the given names (synchronously, whatever thread posts them).
final class DuplicateNotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [Notification.Name: Int] = [:]
    private var tokens: [NSObjectProtocol] = []

    init(_ names: [Notification.Name]) {
        for name in names {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.bump(name)
            })
        }
    }

    private func bump(_ name: Notification.Name) {
        lock.lock()
        counts[name, default: 0] += 1
        lock.unlock()
    }

    func count(_ name: Notification.Name) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[name] ?? 0
    }

    func stop() {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens = []
    }
}

/// The controller's `testOrderingSpy` steps, in order (the production code calls `spy("...")` at the points a quick undo and redo pass).
@MainActor
final class DuplicateSpyLog {
    private(set) var steps: [String] = []
    func note(_ step: String) { steps.append(step) }
    func count(_ step: String) -> Int { steps.filter { $0 == step }.count }
}

@MainActor
final class MarkdownEditorFirstDuplicateTests: XCTestCase {

    var rig: MarkdownClickRig!

    /// Every job-body hold this test made (`holdJobs`, `holdReinserts`). A hold is a SEMAPHORE: each job that reaches it consumes one
    /// `release()`, so a test whose command makes a second job (a second Duplicate, a second undo's reinsert, a refused command that a
    /// bug lets through) needs a second release or that job blocks the writer's thread for ever. The tearDown signals every hold
    /// generously so a bug shows as a red test and not as a stuck run (round C2b: U6 released once for two reinsert jobs).
    private var heldJobs: [MarkdownClickRig.JobHold] = []

    override func setUp() async throws {
        try await super.setUp()
        executionTimeAllowance = 120   // honoured when the run enables test timeouts; the bounded waits below do not depend on it
    }

    override func tearDown() async throws {
        for hold in heldJobs { for _ in 0..<8 { hold.release() } }
        heldJobs = []
        rig?.controller.testEFJobBodyHold = nil
        rig?.controller.testReinsertBodyHold = nil
        rig?.controller.testEFSettleHold = nil
        rig?.controller.testOrderingSpy = nil
        rig?.restore()
        rig = nil
        try await super.tearDown()
    }

    // MARK: - Documents

    static let book =
        "# Chapter 1\n\nFirst chapter text.\n\n# Chapter 2\n\nSecond chapter text.\n\n# Chapter 3\n\nThird chapter text."
    static let book4 =
        "# Chapter 1\n\nFirst chapter text.\n\n# Chapter 2\n\nSecond chapter text.\n\n# Chapter 3\n\nThird chapter text.\n\n"
        + "# Chapter 4\n\nFourth chapter text."
    /// Chapter 2 holds three sub-sections; Part 2.2 holds an image line.
    static let chaptersWithParts =
        "# Chapter 1\n\nFirst chapter text.\n\n# Chapter 2\n\nSecond chapter text.\n\n## Part 2.1\n\nPart one text.\n\n"
        + "## Part 2.2\n\nPart two text.\n\n![A picture](picture.png)\n\n## Part 2.3\n\nPart three text.\n\n# Chapter 3\n\nThird chapter text."

    // MARK: - Helpers

    /// A rig on `markdown` that observes the page (the content record follows it); `undo` wires the real Cmd-Z route.
    func startRig(_ markdown: String, undo: Bool = false) async throws {
        rig = try await MarkdownClickRig(markdown: markdown, observesPage: true, routesUndo: undo)
    }

    // MARK: - Bounded waits (a bug is a red test, never a stuck run)

    struct StuckError: Error, CustomStringConvertible {
        let what: String
        let seconds: Double
        var description: String { "stuck for \(Int(seconds)) s: \(what)" }
    }

    /// Runs `work` and gives up after `seconds`: the test fails with `what` and stops (the stuck work is left running, as `runWithin`
    /// leaves it; the tearDown frees whatever holds it).
    func bounded<T>(_ what: String, seconds: Double = 20, _ work: @escaping @MainActor () async -> T) async throws -> T {
        guard let value = await runWithin(seconds, work) else {
            XCTFail("stuck for \(Int(seconds)) s: \(what)")
            throw StuckError(what: what, seconds: seconds)
        }
        return value
    }

    /// Waits for a command's Task, bounded.
    func finish<T: Sendable>(_ task: Task<T, Never>, _ what: String, seconds: Double = 20) async throws -> T {
        try await bounded("waiting for \(what) to finish (held for ever, or a job that never ends?)", seconds: seconds) { await task.value }
    }

    /// Everything the click started has finished (the job and its settle, the hold, the writer's last write), bounded.
    func settleAll() async throws {
        try await bounded("settling everything the command started (a job or a hold that never ends?)", seconds: 25) {
            await self.rig.settleEverything()
        }
    }

    func settleWriter() async throws {
        try await bounded("the writer's write in flight", seconds: 20) { await self.rig.writerRig.settle() }
    }

    func finishReparse() async throws {
        try await bounded("the debounced re-parse", seconds: 20) { await self.rig.editorState.blockReparseTask?.value }
    }

    func refreshSidebar() async throws {
        try await bounded("the sidebar refresh", seconds: 20) { await self.rig.editorState.refreshSectionsAwaiting() }
    }

    func performDuplicate(rootId: String) async throws -> StructuralUndoController.StructuralOpOutcome {
        try await bounded("the Duplicate click (a hold that is never released?)") {
            await self.rig.controller.performSectionDuplicate(rootId: rootId)
        }
    }

    func performDelete(rootId: String) async throws -> StructuralUndoController.StructuralOpOutcome {
        try await bounded("the Delete click (a hold that is never released?)") { await self.rig.controller.performSectionDelete(rootId: rootId) }
    }

    /// The page and the keyboard, bounded: every call goes through `evaluateJavaScript`, which has no timeout of its own.
    func pageText() async throws -> String {
        let text: String? = try await bounded("reading the page's text (the web view does not answer)", seconds: 10) {
            try? await self.rig.pageText()
        }
        guard let text else {
            XCTFail("the page's text could not be read")
            throw StuckError(what: "the page's text could not be read", seconds: 0)
        }
        return text
    }

    @discardableResult
    func userTypes(_ text: String, after marker: String) async throws -> String {
        let raw: String? = try await bounded("typing into the page (the web view does not answer)", seconds: 10) {
            try? await self.rig.userTypes(text, after: marker)
        }
        guard let raw else {
            XCTFail("typing into the page failed")
            throw StuckError(what: "typing into the page failed", seconds: 0)
        }
        return raw
    }

    func typeIntoPage(_ text: String) async throws {
        let done: Bool? = try await bounded("setting the page's text", seconds: 10) {
            (try? await self.rig.type(text)) != nil
        }
        if done != true { XCTFail("the page's text could not be set") }
    }

    func keyPress(_ direction: String, times: Int = 1) async throws {
        let done: Bool = try await bounded("pressing \(direction) in the page", seconds: 10) {
            (try? await self.rig.press(direction, times: times)) != nil
        }
        if !done { XCTFail("the \(direction) key press could not be sent to the page") }
    }

    /// The rig's `waitForPage` polls for up to `seconds`; this bounds the whole call (every poll is an `evaluateJavaScript`).
    @discardableResult
    func waitForPage(seconds: Double = 8, _ condition: @escaping (String) -> Bool) async throws -> String {
        try await bounded("waiting for the page's text to change (the web view does not answer)", seconds: seconds + 12) {
            (try? await self.rig.waitForPage(seconds: seconds, condition)) ?? ""
        }
    }

    func heldPressCount() async throws -> Int {
        try await bounded("asking the page how many presses it holds", seconds: 10) { (try? await self.rig.heldPressCount()) ?? -1 }
    }

    func releaseTicket(_ ticket: SystemTicket) async throws {
        try await bounded("releasing the held system sequence", seconds: 20) { await self.rig.writerRig.release(ticket) }
    }

    /// The rig's job-body hold, remembered so the tearDown can free it. Each job that reaches it needs one `release()`.
    ///
    /// WATCHDOG (round C2c): a job parked in the hold keeps the database's write transaction open, so a command that is NOT held (a
    /// break patch that releases the hold at the click, or any bug that lets a second command through) can block the MAIN THREAD on a
    /// synchronous database write, and then the test can never reach its own `release()`: no bounded wait helps, because the main
    /// thread is frozen. A background timer therefore signals the hold after 10 s (a healthy test releases it within about a second),
    /// which frees the writer, then the main thread, and the test goes red instead of hanging.
    func holdJobs() -> MarkdownClickRig.JobHold {
        let hold = rig.holdNextJob()
        heldJobs.append(hold)
        Self.armWatchdog(for: hold)
        return hold
    }

    /// The same for the quick undo's reinsert job (each undo makes one).
    func holdReinserts() -> MarkdownClickRig.JobHold {
        let hold = rig.holdReinsert()
        heldJobs.append(hold)
        Self.armWatchdog(for: hold)
        return hold
    }

    private static func armWatchdog(for hold: MarkdownClickRig.JobHold, afterSeconds seconds: Double = 10) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) {
            for _ in 0..<8 { hold.release() }
        }
    }

    /// Duplicate Section through the controller's entry point, by heading title (a row that exists).
    @discardableResult
    func duplicate(_ title: String) async throws -> StructuralUndoController.StructuralOpOutcome {
        let root = try rig.section(title)
        return try await performDuplicate(rootId: root.id)
    }

    /// A command pressed in its own Task, so a test can look at the app while the command waits for an earlier one.
    func startDuplicate(rootId: String) -> Task<StructuralUndoController.StructuralOpOutcome, Never> {
        let controller = rig.controller
        return Task { @MainActor in await controller.performSectionDuplicate(rootId: rootId) }
    }

    /// The sidebar card titled `title` (the overlay shows the copy before its rows exist).
    func card(_ title: String) -> SectionViewModel? {
        rig.editorState.sections.first { $0.title == title }
    }

    /// Every `<!-- @sid:ID -->` marker of a page, in page order, with the rest of its line.
    static func markers(in page: String) -> [PageMarker] {
        guard let regex = try? NSRegularExpression(pattern: "<!-- @sid:([0-9A-Fa-f-]+) -->([^\\n]*)") else { return [] }
        let text = page as NSString
        return regex.matches(in: page, range: NSRange(location: 0, length: text.length)).map {
            PageMarker(id: text.substring(with: $0.range(at: 1)), line: text.substring(with: $0.range(at: 2)))
        }
    }

    /// The title of a heading line: the text after the `#` run.
    static func headingTitle(of line: String) -> String? {
        guard line.hasPrefix("#") else { return nil }
        return line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
    }

    /// The id of the marker in front of the heading titled `title`, if the page has one.
    static func markerId(in page: String, headingTitled title: String) -> String? {
        markers(in: page).first { headingTitle(of: $0.line) == title }?.id
    }

    /// The heading rows titled `title`, in document order.
    func headingRows(_ title: String) throws -> [Block] {
        try rig.writerRig.rows().filter { $0.blockType == .heading && $0.textContent == title }.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// The page as the app has it: every ORIGINAL heading carries its `<!-- @sid:ID -->` marker (the app's rebuild injects them; the
    /// rig's page starts without). The card click finds the FIRST marker of an id, so a copy that kept its source's id would be found
    /// behind the original. Call right after `startRig`, before the click. Headings must have unique text.
    func putMarkersOnTheOriginalHeadings() async throws {
        var page = try await pageText()
        for row in try rig.writerRig.rows() where row.blockType == .heading {
            guard let range = page.range(of: row.markdownFragment) else { continue }
            page.replaceSubrange(range, with: "<!-- @sid:\(row.id) -->" + row.markdownFragment)
        }
        try await typeIntoPage(page)
        let reported = await rig.waitUntil { self.rig.editorState.sourceContent == page }
        if !reported { rig.editorState.sourceContent = page }   // the rig's coordinator reports it; if it has not yet, the record is told
    }

    /// One line per row: id, text, status, tags, goal. What must be the same before and after an undo.
    func rowSnapshot() throws -> [String] {
        try rig.writerRig.rows().sorted { $0.sortOrder < $1.sortOrder }.map {
            "\($0.id)|\($0.markdownFragment)|\($0.status?.rawValue ?? "-")|\(($0.tags ?? []).joined(separator: ","))|\($0.wordGoal ?? 0)"
        }
    }

    /// The non-empty lines of a document, in order: what must agree between the rows and the editor.
    func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func assertRowsMatchPage(_ context: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let page = MarkdownLeaderMap.recordText(fromRaw: try await pageText())
        XCTAssertEqual(lines(try rig.writerRig.storedText()), lines(page), "the rows differ from the editor \(context)", file: file, line: line)
    }

    /// Nothing is left behind by a finished command.
    func assertQuiet(_ context: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(rig.editorState.toastCenter.current, "a notice or progress toast is showing \(context)", file: file, line: line)
        XCTAssertEqual(rig.toastLog.lines, [], "a notice was shown \(context)", file: file, line: line)
        XCTAssertFalse(rig.markdownWriter.isHeldForStructuralWork, "the writer is still held \(context)", file: file, line: line)
        XCTAssertEqual(rig.editorState.pendingReinsertCount, 0, "a reinsert is still pending \(context)", file: file, line: line)
        XCTAssertEqual(rig.editorState.pendingEditorFirstJobs, 0, "an editor-first job is still pending \(context)", file: file, line: line)
    }

    // MARK: - U1

    // CLAIM: after a Duplicate the copy is on the page AT ONCE (the job is still held), its heading's marker id is the id of the copy
    // heading ROW once the job has run, and the page text (markers stripped) is exactly what the rows assemble to.
    func testDuplicateShowsTheCopyAtOnceAndTheRowsMatchThePage() async throws {
        try await startRig(Self.book)
        let hold = holdJobs()
        let chapter3 = try rig.section("Chapter 3")

        let outcome = try await performDuplicate(rootId: chapter3.id)
        XCTAssertEqual(outcome, .performed)
        let pageHeld = try await pageText()
        XCTAssertNotNil(Self.markerId(in: pageHeld, headingTitled: "Chapter 3 copy"), "the copy is not on the page while its job is held")
        XCTAssertTrue(try headingRows("Chapter 3 copy").isEmpty, "premise: the job has not run, so the rows have no copy yet")

        hold.release()
        try await settleAll()
        let page = try await pageText()
        let markerId = try XCTUnwrap(Self.markerId(in: page, headingTitled: "Chapter 3 copy"), "no marker in front of the copy heading")
        let copyRows = try headingRows("Chapter 3 copy")
        XCTAssertEqual(copyRows.count, 1, "wanted exactly one copy heading row, got \(copyRows.count)")
        XCTAssertEqual(copyRows.first?.id, markerId, "row id != marker (the page marker names a different id than the copy heading row)")
        XCTAssertEqual(
            MarkdownLeaderMap.recordText(fromRaw: page), try rig.writerRig.storedText(),
            "page != rows assembly (the page text with the markers stripped is not what the rows assemble to)")
        XCTAssertFalse(rig.markdownWriter.isHeldForStructuralWork)
        XCTAssertTrue(rig.controller.efEditorKind.values.contains(.markdown), "the entry is not recorded as a Markdown editor-first entry")
    }

    // MARK: - U2

    // CLAIM: typing made while the Duplicate's job is held (in the copy's heading, in a body paragraph of the copy, in a copied
    // sub-section) is kept on the page, is NOT saved while the job is held (the writer is held), and is saved after the release: the text
    // is in the rows once, and the original section's rows did not change.
    func testTypingWhileTheDuplicateJobIsHeldIsKeptAndSaved() async throws {
        try await startRig(Self.chaptersWithParts)
        let originalRows = try rowSnapshot()
        let originalIds = Set(try rig.writerRig.rows().map(\.id))
        let hold = holdJobs()
        let chapter2 = try rig.section("Chapter 2")
        let outcome = try await performDuplicate(rootId: chapter2.id)
        XCTAssertEqual(outcome, .performed)
        XCTAssertTrue(rig.markdownWriter.isHeldForStructuralWork, "premise: the job is held, so the hold is up")

        // The user types in the copy: its heading, its first body paragraph, and a copied sub-section (found by the copy's own marker).
        let pageClick = try await pageText()
        let copiedPart = try XCTUnwrap(
            Self.markers(in: pageClick).first { Self.headingTitle(of: $0.line) == "Part 2.1" }?.id, "premise: the copied Part 2.1 has a marker")
        try await userTypes(" hx1", after: "# Chapter 2 copy")
        try await userTypes(" bx2", after: "# Chapter 2 copy hx1\n\nSecond chapter text.")
        try await userTypes(" cx3", after: "<!-- @sid:\(copiedPart) -->## Part 2.1\n\nPart one text.")
        let reported = await rig.waitUntil { self.rig.editorState.content.contains("cx3") }
        XCTAssertTrue(reported, "premise: the typing reached the content record")
        // The debounced re-parse comes due during the hold: it must reserve nothing.
        _ = rig.writerRig.schedule(rig.editorState.content)
        try await finishReparse()
        let storedWhileHeld = try rig.writerRig.storedText()
        XCTAssertFalse(
            storedWhileHeld.contains("hx1") || storedWhileHeld.contains("bx2") || storedWhileHeld.contains("cx3"),
            "typing saved while the job was held (the hold was released at the click)")
        let pageWhileHeld = try await pageText()
        for typed in ["hx1", "bx2", "cx3"] {
            XCTAssertTrue(pageWhileHeld.contains(typed), "\(typed) was overwritten on the page while the job was held")
        }

        hold.release()
        try await settleAll()
        try await finishReparse()
        try await settleWriter()
        let page = try await pageText()
        let stored = try rig.writerRig.storedText()
        for typed in ["hx1", "bx2", "cx3"] {
            XCTAssertTrue(page.contains(typed), "\(typed) is not on the page after the release")
            XCTAssertEqual(stored.components(separatedBy: typed).count - 1, 1, "\(typed) must be in the rows exactly once")
        }
        XCTAssertEqual(
            try headingRows("Chapter 2 copy hx1").count + (try headingRows("Chapter 2 copy").count), 1,
            "wanted exactly one copy of Chapter 2 in the rows (two sets of copy rows?)")
        let after = try rig.writerRig.rows().filter { originalIds.contains($0.id) }.sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(
            after.map {
                "\($0.id)|\($0.markdownFragment)|\($0.status?.rawValue ?? "-")|\(($0.tags ?? []).joined(separator: ","))|\($0.wordGoal ?? 0)"
            },
            originalRows, "the original section's rows changed (only the copy's rows may)")
        try await assertRowsMatchPage("after the typing in the copy was saved")
    }

    // MARK: - U3

    // CLAIM: typing made just before the click (the content record lags the page) is saved WITH the click: it is in the rows while the
    // job is still held.
    func testTypingJustBeforeTheClickIsSavedWithIt() async throws {
        rig = try await MarkdownClickRig(markdown: Self.book)
        let hold = holdJobs()
        let chapter3 = try rig.section("Chapter 3")
        try await userTypes(" zq7", after: "Second chapter text.")
        XCTAssertEqual(rig.editorState.content, Self.book, "premise: the content record lags the page (nothing reported the typing)")

        let outcome = try await performDuplicate(rootId: chapter3.id)
        XCTAssertEqual(outcome, .performed)
        // The job is held: step 8's flush cannot have saved anything yet, so only the click's own typing batch can have put zq7 there.
        let batchSaved = await rig.waitUntil { (try? self.rig.writerRig.storedText().contains("Second chapter text. zq7")) == true }
        XCTAssertTrue(batchSaved, "typing lost: zq7 not in the rows before the job ran")
        XCTAssertTrue(try headingRows("Chapter 3 copy").isEmpty, "premise: the job has not run yet")

        hold.release()
        try await settleAll()
        let stored = try rig.writerRig.storedText()
        XCTAssertTrue(stored.contains("Second chapter text. zq7"), "typing lost: zq7 not in the rows")
        XCTAssertEqual(try headingRows("Chapter 3 copy").count, 1, "the copy is not in the rows")
        let page = try await pageText()
        XCTAssertTrue(page.contains("zq7"))
        XCTAssertFalse(rig.markdownWriter.isHeldForStructuralWork)
    }
}
