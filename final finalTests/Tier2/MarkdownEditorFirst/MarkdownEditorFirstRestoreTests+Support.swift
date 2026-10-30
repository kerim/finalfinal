//
//  MarkdownEditorFirstRestoreTests+Support.swift
//  final finalTests
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), slice 4, round C2: what the tests of the Markdown editor-first Version
//  History restores share (MarkdownEditorFirstRestoreTests.swift: the click; +Undo: Cmd-Z and Cmd-Shift-Z; +Failure: the old body taken
//  and the failed job; +Typing: typing around the click and the hold). Helpers only, nothing here is a test. Modelled on
//  MarkdownEditorFirstDuplicateTests.swift (the same rig, the same bounded waits).
//
//  HOW A TEST SETS A RESTORE UP, as the Version History window does. The `section` table is filled BEFORE the version is saved (a
//  version holds the table's sections: `saveVersion`), the document is changed afterwards (`typeAndSave`: typing into the page that the
//  writer then saves into the rows), and the table is filled AGAIN when the test wants the window's picture to be current
//  (`syncSectionTable`). The rig has no ContentView: a restore press is the controller's own entry point
//  (`performRestoreProject`, `performSectionRestoreReplace`, `performRestoreSectionDuplicate`).
//
//  NO TRACE SINK. The `[STRUCT-TRACE] ...` lines go through `DebugLog.log(.undo, ...)`, which has no test sink (only the
//  always-persisted lines do: `RestoreAlwaysLog`). Where a brief names a trace line, the test reads the controller's ordering spy
//  (`testOrderingSpy`: `quickUndoRestoreApplied` sits right after the `start (quick, markdown)` line of a quick undo,
//  `markdownSlowSwapReserved` is the queued route) and the persisted lines, and says so in its CLAIM.
//
//  Needs `cd web && pnpm build` first (the host tests load the built bundle). NOT RUN by the coder.
//

import Foundation
import XCTest
@testable import final_final

/// Every always-persisted log line of the process while it lives (not filtered by project: the queued route's line carries only an op
/// id). Stop it in `tearDown`.
final class RestoreAlwaysLog: @unchecked Sendable {
    private let lock = NSLock()
    private var kept: [String] = []
    private var token: UUID?

    init() {
        token = DebugLog.addAlwaysObserver { [weak self] line in self?.append(line) }
    }

    private func append(_ line: String) {
        lock.lock()
        kept.append(line)
        lock.unlock()
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return kept
    }

    func stop() {
        if let token { DebugLog.removeAlwaysObserver(token) }
        token = nil
    }
}

extension MarkdownEditorFirstRestoreTests {

    // MARK: - Documents

    static let book =
        "# Chapter 1\n\nFirst chapter text.\n\n# Chapter 2\n\nSecond chapter text.\n\n# Chapter 3\n\nThird chapter text.\n\n"
        + "# Chapter 4\n\nFourth chapter text."

    /// Notes and a Bibliography after the chapters (the shape of MarkdownEditorFirstDuplicateTests+Hold's U9 document).
    static let bibliographyEntries =
        "# Bibliography\n\nSmith, J. (2020). A book.\n\nJones, K. (2021). Another.\n\n<!-- ::auto-bibliography-end:: -->"
    static let bibliographyBook =
        "# Chapter 1\n\nFirst chapter text.[^1]\n\n# Chapter 2\n\nSecond chapter text.\n\n## Notes\n\n[^1]: Note one.\n\n"
        + bibliographyEntries
    static let openingBibliographyMarker = "<!-- ::auto-bibliography:: -->"

    /// Two footnotes, each in its own chapter, and the Notes.
    static let footnotedBook =
        "# Chapter 1\n\nFirst chapter text.[^1]\n\n# Chapter 2\n\nSecond chapter text.\n\n# Chapter 3\n\nThird chapter text.[^2]\n\n"
        + "## Notes\n\n[^1]: Note one.\n\n[^2]: Note two."

    // MARK: - The rig

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

    func bounded<T>(_ what: String, seconds: Double = 20, _ work: @escaping @MainActor () async -> T) async throws -> T {
        guard let value = await runWithin(seconds, work) else {
            XCTFail("stuck for \(Int(seconds)) s: \(what)")
            throw StuckError(what: what, seconds: seconds)
        }
        return value
    }

    func finish<T: Sendable>(_ task: Task<T, Never>, _ what: String, seconds: Double = 20) async throws -> T {
        try await bounded("waiting for \(what) to finish (held for ever, or a job that never ends?)", seconds: seconds) { await task.value }
    }

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

    func releaseTicket(_ ticket: SystemTicket) async throws {
        try await bounded("releasing the held system sequence", seconds: 20) { await self.rig.writerRig.release(ticket) }
    }

    // MARK: - The page and the keyboard, bounded

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
        let done: Bool? = try await bounded("setting the page's text", seconds: 10) { (try? await self.rig.type(text)) != nil }
        if done != true { XCTFail("the page's text could not be set") }
    }

    func keyPress(_ direction: String, times: Int = 1) async throws {
        let done: Bool = try await bounded("pressing \(direction) in the page", seconds: 10) {
            (try? await self.rig.press(direction, times: times)) != nil
        }
        if !done { XCTFail("the \(direction) key press could not be sent to the page") }
    }

    @discardableResult
    func waitForPage(seconds: Double = 8, _ condition: @escaping (String) -> Bool) async throws -> String {
        try await bounded("waiting for the page's text to change (the web view does not answer)", seconds: seconds + 12) {
            (try? await self.rig.waitForPage(seconds: seconds, condition)) ?? ""
        }
    }

    func heldPressCount() async throws -> Int {
        try await bounded("asking the page how many presses it holds", seconds: 10) { (try? await self.rig.heldPressCount()) ?? -1 }
    }

    /// A real keydown; waits until the page's text satisfies `condition`, then until the structural gate and everything the press started
    /// have finished.
    @discardableResult @nonobjc   // internal on an XCTestCase: without `@nonobjc` its async ObjC thunk would capture the non-escaping closure
    func press(_ direction: String, until condition: @escaping (String) -> Bool, _ message: String) async throws -> String {
        try await keyPress(direction)
        let text = try await waitForPage(condition)
        XCTAssertTrue(condition(text), message)
        _ = await rig.waitUntil { self.rig.editorState.structuralGate.isIdle }
        try await settleAll()
        return text
    }

    /// Waits until `count` commands are parked in `awaitStructuralHoldReleased()` (the writer keeps them in `structuralHoldState.waiters`).
    /// A SIGNAL for "the command reached its wait": the tests that follow it assert what has not happened yet without a pause.
    @discardableResult
    func waitForParkedCommand(_ what: String, count: Int = 1, file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        let parked = await rig.waitUntil(8) { self.rig.markdownWriter.structuralHoldState.waiters.count >= count }
        XCTAssertTrue(parked, "premise: \(what) is parked at the writer's hold", file: file, line: line)
        return parked
    }

    // MARK: - Keeping a running Zotero out of a test that has a Bibliography

    /// Every applied restore's settle runs `BibliographySyncService.resyncNow` with the citekeys of the text (`resyncAfterEditorFirstDelete`).
    /// With NO citekey that is `performBibliographyUpdate` -> `removeBibliographyBlock`, which deletes every bibliography row, but only
    /// when `ZoteroService.shared.isConnected` (the guard right after the staleness checks returns first otherwise). On a Mac with Zotero
    /// and Better BibTeX running the process-wide service can be connected, and a document whose Bibliography has no citation in its text
    /// then loses the Bibliography rows after the job (the same thing the Delete, Duplicate and Reorder last-chapter tests of this folder
    /// show on a Mac with Zotero running, board t-ab496135). A document without Bibliography rows is not touched (the removal finds
    /// nothing to delete). So a test whose document HAS a Bibliography pins both: the shared service disconnected (put back in the
    /// tearDown), and this rig's own bibliography service told its text was edited by hand (`resyncNow` then returns at once), which
    /// holds even if something in the process connects the shared service again meanwhile. The rig has no seam of its own for this.
    func keepTheBibliographyAwayFromZotero() {
        if priorZoteroConnected == nil { priorZoteroConnected = ZoteroService.shared.isConnected }
        ZoteroService.shared.isConnected = false
        rig.bibliography.markAsManuallyEdited()
    }

    // MARK: - Job-body holds (the rig's `testEFJobBodyHold` seam, with the watchdog of the Duplicate's tests)

    /// A semaphore: each job that reaches it needs one `release()`. A background timer frees it after 10 s, so a command that a bug lets
    /// through (and that would block the main thread on the held job's write transaction) turns the test red instead of hanging it.
    func holdJobs() -> MarkdownClickRig.JobHold {
        let hold = rig.holdNextJob()
        heldJobs.append(hold)
        Self.armWatchdog(for: hold)
        return hold
    }

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

    // MARK: - Versions and presses

    /// Fills the `section` table from the content record, as opening Version History does (it syncs the table from the editor's text).
    func syncSectionTable() async {
        await rig.sectionSync.syncNow(rig.editorState.content)
    }

    /// A manual version of the document as it is now. The section table is filled first: a version holds the table's sections.
    func saveVersion(name: String = "before-restore") async throws -> Snapshot {
        await syncSectionTable()
        return try SnapshotService(database: rig.db, projectId: rig.pid).createManualSnapshot(name: name)
    }

    /// The user types `text` after `marker` in the page and the typing is saved into the rows (the writer's fire), so the document
    /// differs from a version saved earlier and the rows agree with the page.
    func typeAndSave(_ text: String, after marker: String) async throws {
        try await userTypes(text, after: marker)
        let reported = await rig.waitUntil { self.rig.editorState.content.contains(text) }
        XCTAssertTrue(reported, "premise: the typing reached the content record")
        await rig.writerRig.fireAndSettle(rig.editorState.content)
    }

    func snapshotSectionId(_ title: String, in version: Snapshot) throws -> String {
        try XCTUnwrap(
            try rig.db.fetchSnapshotSections(snapshotId: version.id).first { $0.title == title }, "the version has no section titled \(title)").id
    }

    func liveSectionId(_ title: String) throws -> String {
        try XCTUnwrap(try rig.db.fetchSections(projectId: rig.pid).first { $0.title == title }, "the section table has no \(title)").id
    }

    /// The id of the LAST row of the section table: what the Version History window passes as the anchor of Insert as New Section.
    func lastSectionId() throws -> String? {
        try rig.db.fetchSections(projectId: rig.pid).sorted { $0.sortOrder < $1.sortOrder }.last?.id
    }

    func restoreProject(from version: Snapshot) async throws -> StructuralUndoController.StructuralOpOutcome {
        try await bounded("the Restore Entire Project click (a hold that is never released?)") {
            await self.rig.controller.performRestoreProject(snapshotId: version.id, requestingProjectId: self.rig.pid)
        }
    }

    func replaceSection(_ title: String, from version: Snapshot) async throws -> StructuralUndoController.StructuralOpOutcome {
        let source = try snapshotSectionId(title, in: version)
        let target = try liveSectionId(title)
        return try await bounded("the Replace Current Section click (a hold that is never released?)") {
            await self.rig.controller.performSectionRestoreReplace(
                snapshotSectionId: source, targetSectionId: target, requestingProjectId: self.rig.pid)
        }
    }

    func insertAsNewSection(_ title: String, from version: Snapshot) async throws -> StructuralUndoController.StructuralOpOutcome {
        let source = try snapshotSectionId(title, in: version)
        let anchor = try lastSectionId()
        return try await bounded("the Insert as New Section click (a hold that is never released?)") {
            await self.rig.controller.performRestoreSectionDuplicate(
                snapshotSectionId: source, insertAfterSectionId: anchor, requestingProjectId: self.rig.pid)
        }
    }

    /// Replace Current Section pressed in its own Task, so a test can look at the app while the command waits for an earlier one.
    func startReplace(_ title: String, from version: Snapshot) throws -> Task<StructuralUndoController.StructuralOpOutcome, Never> {
        let source = try snapshotSectionId(title, in: version)
        let target = try liveSectionId(title)
        let controller = rig.controller
        let pid = rig.pid
        return Task { @MainActor in
            await controller.performSectionRestoreReplace(snapshotSectionId: source, targetSectionId: target, requestingProjectId: pid)
        }
    }

    func performDelete(rootId: String) async throws -> StructuralUndoController.StructuralOpOutcome {
        try await bounded("the Delete click (a hold that is never released?)") { await self.rig.controller.performSectionDelete(rootId: rootId) }
    }

    // MARK: - Reading the rows and the page

    func headingRows(_ title: String) throws -> [Block] {
        try rig.writerRig.rows().filter { $0.blockType == .heading && $0.textContent == title }.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// One line per row: id, text, status, tags, goal. What must be the same before and after an undo.
    func rowSnapshot() throws -> [String] {
        try rig.writerRig.rows().sorted { $0.sortOrder < $1.sortOrder }.map {
            "\($0.id)|\($0.markdownFragment)|\($0.status?.rawValue ?? "-")|\(($0.tags ?? []).joined(separator: ","))|\($0.wordGoal ?? 0)"
        }
    }

    func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
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

    /// The card a heading has in the sidebar (the first card of that title).
    func card(_ title: String) -> SectionViewModel? {
        rig.editorState.sections.first { $0.title == title }
    }

    // MARK: - The page's markers

    func markers(in page: String) -> [PageMarker] {
        guard let regex = try? NSRegularExpression(pattern: "<!-- @sid:([0-9A-Fa-f-]+) -->([^\\n]*)") else { return [] }
        let text = page as NSString
        return regex.matches(in: page, range: NSRange(location: 0, length: text.length)).map {
            PageMarker(id: text.substring(with: $0.range(at: 1)), line: text.substring(with: $0.range(at: 2)))
        }
    }

    func headingTitle(of line: String) -> String? {
        guard line.hasPrefix("#") else { return nil }
        return line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
    }

    /// The ids of the markers in front of the headings titled `title`, in page order.
    func markerIds(in page: String, headingTitled title: String) -> [String] {
        markers(in: page).filter { headingTitle(of: $0.line) == title }.map(\.id)
    }

    // MARK: - The rebuild's text

    /// The page text the app's rebuild makes from the rows as they are NOW: `ContentView.updateSourceContentIfNeeded`'s recipe (Views/
    /// ContentView+ContentRebuilding.swift: "Get non-bibliography sections in sort order" to `sourceContent =`), written out here
    /// independently of `RestorePlan.markdownPageText`: the editor text is `assembleMarkdownForEditor` of the rows; the sections are what
    /// `fetchOutlineBlocks` lists (every heading and section break row, Notes and Bibliography included), the non-bibliography ones in
    /// sort order get a block offset (Characters, "\n\n" between blocks, `MarkdownBlockDiff.assemblyOrderedNonEmpty`, only where the
    /// section has a non-empty fragment); `injectSectionAnchors` writes the markers, `injectBibliographyMarker` (given ALL the
    /// sections) the opening bibliography marker.
    func rebuildRecipeText() throws -> String {
        let rows = try rig.db.fetchBlocks(projectId: rig.pid)
        let content = BlockParser.assembleMarkdownForEditor(from: rows)
        let sections = try rig.db.fetchOutlineBlocks(projectId: rig.pid).map { SectionViewModel(from: $0) }
        let forAnchors = sections.filter { !$0.isBibliography }.sorted { $0.sortOrder < $1.sortOrder }
        var blockOffset: [String: Int] = [:]
        var offset = 0
        for (index, block) in MarkdownBlockDiff.assemblyOrderedNonEmpty(rows).enumerated() {
            if index > 0 { offset += 2 }
            blockOffset[block.id] = offset
            offset += block.markdownFragment.count
        }
        var adjusted: [SectionViewModel] = []
        for section in forAnchors {
            if let startOffset = blockOffset[section.id] { adjusted.append(section.withUpdates(startOffset: startOffset)) }
        }
        let withAnchors = rig.sectionSync.injectSectionAnchors(markdown: content, sections: adjusted)
        return rig.sectionSync.injectBibliographyMarker(markdown: withAnchors, sections: sections)
    }

    /// Puts the page in the state the app has it in: the rebuild's text (every heading carries its `<!-- @sid:ID -->` marker, the
    /// bibliography its opening marker). The rig's page starts without them.
    func putTheAppsMarkersOnThePage() async throws {
        let page = try rebuildRecipeText()
        try await typeIntoPage(page)
        let reported = await rig.waitUntil { self.rig.editorState.sourceContent == page }
        if !reported { rig.editorState.sourceContent = page }   // the rig's coordinator reports it; if it has not yet, the record is told
    }

    /// The automatic versions (the undo points the restore jobs write), oldest first.
    func automaticVersions() throws -> [Snapshot] {
        try SnapshotService(database: rig.db, projectId: rig.pid).fetchAllSnapshots().filter(\.isAutomatic)
            .sorted { $0.createdAt < $1.createdAt }
    }
}
