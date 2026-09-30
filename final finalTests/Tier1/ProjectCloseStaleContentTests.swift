//
//  ProjectCloseStaleContentTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Regression test for TLA+ Finding #5 (docs/architecture/tla/DocSyncCurrent.tla) --
//  closing a project could silently save a stale copy of the document over the real,
//  most-recent edit.
//
//  Mechanism: performProjectClose() used to flush editorState.content directly
//  (editorState.flushAllSync()) instead of fetching fresh content from the WebView
//  first, the way project switch (handleProjectOpened -> flushAllPendingContent) and
//  quit (EditorViewState+Quit.swift's flushForQuit()) already did. If the last
//  JS -> Swift content push was dropped mid-rebuild, zoom, or heading fix,
//  editorState.content stays stale while the poll drain immediately above (in
//  performProjectClose) has just written the user's REAL, newer edit to the
//  database -- and the close-time flush then silently overwrote that real edit with
//  the stale copy, with no error surfaced anywhere.
//
//  Fix: performProjectClose(fetchContent:) now routes through
//  flushAllPendingContent(fetchContent:) (ContentView+VersionHistory.swift) -- the
//  same helper project switch uses -- instead of editorState.flushAllSync(). See
//  ContentView+ProjectLifecycle.swift's performProjectClose(fetchContent:) doc
//  comment and DocSyncCurrent.tla's GuardFetchOnClose.
//
//  Test (c) covers a related bug found while fixing this:
//  ContentView.fetchContentFromWebView's "2s timeout" used a withTaskGroup whose
//  evaluateJavaScript child is a withCheckedContinuation that group.cancelAll()
//  cannot resume -- so if WebKit never calls back, the timeout never actually let
//  the function return. See ContentView.raceContentFetch's own doc comment for the
//  fix: it now goes through the shared raceAgainstTimeout(_:_:) helper
//  (Services/TimeoutRace.swift), the same one BlockSyncService.fetchContentFromWebView
//  itself was migrated to (t-027c3835, quitting-can-hang-if-the-editor-stops-responding)
//  after this test first exposed the pattern.
//

import Testing
import Foundation
@testable import final_final

@Suite(.serialized)
@MainActor
struct ProjectCloseStaleContentTests {

    // MARK: - Fixtures

    /// The document as the poll drain saved it -- what's already in the database by
    /// the time performProjectClose's flush runs.
    private let settled = "# Close Project\n\nSettled paragraph."

    /// The real, most-recent edit -- what a live WebView fetch would return if the
    /// last JS -> Swift push had actually landed.
    private let fresh = "# Close Project\n\nSettled paragraph, PLUS last keystrokes."

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: "/tmp/claude/ProjectCloseStaleContentTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        TestFixtureCleanup.register(dir)
        return dir
    }

    /// Small struct instead of a 3-element tuple (SwiftLint `large_tuple`) for
    /// `makeContentViewFixture` below.
    private struct ContentViewFixture {
        let db: ProjectDatabase
        let projectId: String
        let view: ContentView
    }

    /// Constructs a bare, unmounted ContentView wired to a fresh fixture -- same
    /// "plain struct, internal @State properties, directly constructible" pattern as
    /// ProjectSwitchStaleContentPushTests.makeContentViewFixture().
    private func makeContentViewFixture(
        in dir: URL, name: String, content: String
    ) throws -> ContentViewFixture {
        let fixtureURL = dir.appendingPathComponent("\(name).ff")
        let db = try TestFixtureFactory.createFixture(at: fixtureURL, title: name, content: content)
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        var view = ContentView()
        view.editorState.projectDatabase = db
        view.editorState.currentProjectId = projectId

        return ContentViewFixture(db: db, projectId: projectId, view: view)
    }

    /// Assemble the DB's current block content back into markdown, the same way
    /// ContentView.loadInitialContent does when a project opens.
    private func assembledDatabaseContent(from db: ProjectDatabase) throws -> String {
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        return BlockParser.assembleMarkdownForEditor(from: blocks)
    }

    // MARK: - (a) Real regression assertion -- drives performProjectClose itself

    @Test("performProjectClose does not overwrite a drained edit with a stale editorState.content copy")
    func closeDoesNotOverwriteDrainedEditWithStaleCopy() async throws {
        let dir = try makeTempDir()

        // The database already holds the edit the poll drain saved -- the REAL,
        // most-recent content, exactly as it would be immediately after
        // blockSyncService.stopPollingAndDrain() inside performProjectClose().
        let fixture = try makeContentViewFixture(in: dir, name: "CloseDoesNotOverwrite", content: fresh)
        let (db, view) = (fixture.db, fixture.view)
        defer {
            view.editorState.projectDatabase = nil
            TestDatabaseTeardown.closeThenCleanUp(dir, db)
        }

        // editorState.content is the STALE copy: the last JS -> Swift push was
        // dropped mid-rebuild/zoom/heading-fix, so it never caught up to what the
        // drain above already wrote.
        view.editorState.content = settled

        // fetchContent stands in for a live WebView reply -- the fresh, real content.
        await view.performProjectClose(fetchContent: { self.fresh })

        let dbContent = try assembledDatabaseContent(from: db)
        #expect(
            dbContent.contains("PLUS last keystrokes"),
            "performProjectClose must not overwrite the drain's real edit with stale editorState.content"
        )
    }

    // MARK: - (a2) Real regression assertion -- the fetch is used even when the DB agrees

    @Test("performProjectClose writes the fetched content even when the database already matches editorState.content")
    func closeWritesFetchedContentWhenEditorAndDatabaseAlreadyAgree() async throws {
        let dir = try makeTempDir()

        // A7 (review round 2): test (a) above seeds the DB with `fresh` AND has the fetch
        // return `fresh`, so it would still pass even if performProjectClose wrote nothing
        // at all. Here the DB and editorState.content start out agreeing (both `settled` --
        // "the keystrokes still inside the 50ms debounce" case, not a drain-vs-stale race),
        // and only the fetch carries the newer text, so the assertion below can only pass if
        // the fetched content was actually written.
        let fixture = try makeContentViewFixture(in: dir, name: "CloseWritesFetchedContent", content: settled)
        let (db, view) = (fixture.db, fixture.view)
        defer {
            view.editorState.projectDatabase = nil
            TestDatabaseTeardown.closeThenCleanUp(dir, db)
        }

        view.editorState.content = settled

        await view.performProjectClose(fetchContent: { self.fresh })

        let dbContent = try assembledDatabaseContent(from: db)
        #expect(
            dbContent.contains("PLUS last keystrokes"),
            "performProjectClose must write the fetched content, not just leave the DB's already-settled copy in place"
        )
    }

    // MARK: - (b) Regression guard -- fetch failure falls back to editorState.content

    @Test("performProjectClose falls back to editorState.content (not the database's older copy) when the WebView fetch fails")
    func closeFallsBackWhenFetchFails() async throws {
        let dir = try makeTempDir()

        // A8 (review round 2): the DB is seeded with the OLDER `settled` text -- standing in
        // for whatever the database happened to hold before close began -- while
        // editorState.content holds the NEWER `fresh` text, the same way it would if the
        // last JS -> Swift push landed normally but the fetch (the one this test exercises
        // failing) simply couldn't reach the WebView. Seeding both with the SAME text (as
        // this test used to) made the assertion below pass even if the fallback flush never
        // ran at all -- the DB already had "Settled paragraph." before close started.
        let fixture = try makeContentViewFixture(in: dir, name: "CloseFallsBackOnFetchFailure", content: settled)
        let (db, view) = (fixture.db, fixture.view)
        defer {
            view.editorState.projectDatabase = nil
            TestDatabaseTeardown.closeThenCleanUp(dir, db)
        }

        view.editorState.content = fresh

        await view.performProjectClose(fetchContent: { nil })

        let dbContent = try assembledDatabaseContent(from: db)
        #expect(
            dbContent.contains("PLUS last keystrokes"),
            "a failed fetch must fall back to editorState.content (the newer text), not leave the database's older copy in place"
        )
    }

    // MARK: - (c) raceContentFetch's timeout is real, not group-joined

    /// Parks a continuation until `open()` is called -- stands in for a WebKit
    /// `evaluateJavaScript` callback that never arrives.
    @MainActor
    private final class TestGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { self.continuation = $0 }
        }

        func open() {
            isOpen = true
            let pending = continuation
            continuation = nil
            pending?.resume()
        }
    }

    @Test("ContentView.raceContentFetch actually returns at the timeout, not when the raced work finally finishes")
    func raceContentFetchTimeoutIsReal() async throws {
        let gate = TestGate()
        // Safety net: if the race under test is broken and never returns on its own
        // timeout, don't hang the suite forever -- release the parked work from the
        // side after 3s so this test still completes (and its own timing assertion
        // below still correctly fails).
        let safety = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            gate.open()
        }
        defer { safety.cancel() }

        let clock = ContinuousClock()
        let start = clock.now
        let result = await ContentView.raceContentFetch(timeout: .milliseconds(300)) {
            await gate.wait()
            return "late"
        }
        let elapsed = clock.now - start

        #expect(result == nil, "the timeout must win when the raced work never finishes in time")
        #expect(
            elapsed < .seconds(2),
            "raceContentFetch must return at the timeout, not join the still-running raced work"
        )

        gate.open()
    }

    // MARK: - (d) A1 -- closing while zoomed must not delete Section rows outside the zoom

    /// Regression test for review round 2's A1: `performProjectClose` now shares
    /// `flushAllPendingContent` with project switch (this task, TLA+ Finding #5), and while
    /// zoomed, `contentToFlush` there is only the zoomed subset's markdown. Without the
    /// zoom guard on the section-sync step (`ContentView+VersionHistory.swift`), reconciling
    /// that subset's headers alone against EVERY `Section` row in the project makes
    /// `SectionReconciler.reconcile`'s delete sweep treat every row outside the zoom as
    /// unmatched and hard-delete it -- the old close path (`SectionSyncService.syncNowSync`)
    /// had this exact guard (`guard !isContentZoomed else { return }`) built in; routing
    /// close through the shared switch path lost it until the fix.
    @Test("closing while zoomed does not delete the Section row outside the zoom")
    @MainActor
    func closeWhileZoomedPreservesSectionOutsideZoom() async throws {
        let dir = try makeTempDir()
        let twoSectionContent = "# Section A\n\nContent A.\n\n# Section B\n\nContent B.\n"

        let fixture = try makeContentViewFixture(in: dir, name: "CloseWhileZoomed", content: twoSectionContent)
        let (db, projectId, view) = (fixture.db, fixture.projectId, fixture.view)
        defer {
            view.editorState.projectDatabase = nil
            TestDatabaseTeardown.closeThenCleanUp(dir, db)
        }

        // The bare fixture (TestFixtureFactory.createFixture) only seeds Block rows, not
        // Section rows -- those are normally populated by configureForCurrentProject()'s own
        // `sectionSyncService.syncNow(editorState.content)` call on project open. Reproduce
        // that here so both sections actually exist as Section rows before close runs.
        view.sectionSyncService.configure(database: db, projectId: projectId)
        view.sectionSyncService.editorState = view.editorState
        await view.sectionSyncService.syncNow(twoSectionContent)

        let sectionsBeforeClose = try db.fetchSections(projectId: projectId)
        #expect(sectionsBeforeClose.count == 2)
        let sectionA = try #require(sectionsBeforeClose.first { $0.title == "Section A" })
        let sectionB = try #require(sectionsBeforeClose.first { $0.title == "Section B" })

        // Zoom into Section A. While zoomed, editorState.content (and a live WebView fetch)
        // only ever holds the zoomed subset's markdown -- Section B is simply absent from it,
        // not because the user touched it.
        view.editorState.zoomedSectionId = sectionA.id
        let zoomedContent = "# Section A\n\nContent A, PLUS last keystrokes.\n"
        view.editorState.content = zoomedContent

        await view.performProjectClose(fetchContent: { zoomedContent })

        let sectionsAfterClose = try db.fetchSections(projectId: projectId)
        #expect(
            sectionsAfterClose.contains { $0.id == sectionB.id },
            "closing while zoomed must not delete the Section row outside the zoom (\(sectionsAfterClose.map(\.title)))"
        )
    }

    // MARK: - (e) A9 -- close with a pending bibliography rebuild uses the fetched content

    /// Regression test for review round 2's A9: `performProjectClose` now reaches
    /// `EditorViewState.flushPendingBibliographyAndFootnoteSync(overrideContent:)` --
    /// previously only reached from project switch (review round 1's "bibliography-flush
    /// clobber" must-fix). Proves close threads the SAME fetched content through that path
    /// too, rather than letting the bibliography rebuild's own flush hook
    /// (`ContentView.makeBibliographyFlushHandler`) fall back to reading the stale
    /// `editorState.content` directly. The flush hook is `private` (file-scoped) and not
    /// reachable from this file, so this mirrors its exact production guard sequence --
    /// same technique as `BibliographySourceModeFlushTests.swift`'s `productionFlushHook`.
    @Test("close with a pending bibliography rebuild flushes the fetched content, not stale editorState.content")
    @MainActor
    func closeWithPendingBibliographyRebuildUsesFetchedContent() async throws {
        let dir = try makeTempDir()
        let staleContent = "# Close Project\n\nSee reference [@closebibkey2026] here for details."
        let fetchedContent = "# Close Project\n\nSee reference [@closebibkey2026] here for details, PLUS last keystrokes."

        let fixture = try makeContentViewFixture(in: dir, name: "CloseWithPendingBib", content: staleContent)
        let (db, projectId, view) = (fixture.db, fixture.projectId, fixture.view)
        defer {
            view.editorState.projectDatabase = nil
            TestDatabaseTeardown.closeThenCleanUp(dir, db)
        }

        let itemJSON = """
        {"id":"closebibkey2026","type":"book","title":"Close Bib Title",\
        "author":[{"family":"Closefam","given":"Clara"}],"issued":{"date-parts":[[2024]]}}
        """
        let item = try JSONDecoder().decode(CSLItem.self, from: Data(itemJSON.utf8))
        ZoteroService.shared.isConnected = true
        ZoteroService.shared.loadItem(item)
        defer {
            ZoteroService.shared.isConnected = false
            ZoteroService.shared.clearCache()
        }

        view.editorState.editorMode = .source
        view.bibliographySyncService.configure(database: db, projectId: projectId)
        view.editorState.bibliographySyncService = view.bibliographySyncService

        // Mirrors ContentView.makeBibliographyFlushHandler()'s production guard sequence
        // (ContentView+ProjectLifecycle.swift) -- that method is `private`, so a test can't
        // call it, exactly the situation BibliographySourceModeFlushTests.swift's
        // productionFlushHook already documents its own equivalent for.
        let flushHook: (String, String?) async -> Void = { [weak editorState = view.editorState] scheduledForProjectId, overrideContent in
            guard let editorState,
                  editorState.contentState == .idle,
                  editorState.editorMode == .source,
                  editorState.zoomedSectionId == nil,
                  editorState.currentProjectId == scheduledForProjectId else { return }
            editorState.flushContentToDatabase(overrideContent: overrideContent)
        }
        view.bibliographySyncService.flushLiveEditorContentToBlocks = flushHook

        // Schedule the pending rebuild -- the bibliography debounce is in flight ("pending",
        // not yet fired) exactly as it would be if a citation was inserted just before the
        // user closed the project.
        let citekeys = BibliographySyncService.extractCitekeys(from: staleContent)
        view.bibliographySyncService.checkAndUpdateBibliography(currentCitekeys: citekeys, projectId: projectId)

        // editorState.content is the STALE copy (mirrors test (a)/(a2)): the last JS -> Swift
        // push was dropped, so it never caught up to what a live fetch would return.
        view.editorState.content = staleContent

        await view.performProjectClose(fetchContent: { fetchedContent })

        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)
        let nonBibBlocks = blocksAfter.filter { !$0.isBibliography }
        let assembled = BlockParser.assembleMarkdown(from: nonBibBlocks)
        #expect(
            assembled.contains("PLUS last keystrokes"),
            "close's pending-bibliography-rebuild flush hook must use the fetched content, not stale editorState.content"
        )
    }
}
