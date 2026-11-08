//
//  ProjectCloseStaleContentTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Regression test for TLA+ Finding #5 (docs/architecture/tla/DocSyncCurrent.tla) --
//  closing a project could silently save a stale copy of the document over the real,
//  most-recent edit.
//
//  Mechanism: closing a project used to flush editorState.content directly
//  (editorState.flushAllSync()) instead of fetching fresh content from the WebView
//  first, the way project switch and quit already did. If the last
//  JS -> Swift content push was dropped mid-rebuild, zoom, or heading fix,
//  editorState.content stays stale while the poll drain immediately above the flush
//  has just written the user's REAL, newer edit to the database -- and the close-time
//  flush then silently overwrote that real edit with the stale copy, with no error
//  surfaced anywhere.
//
//  PORTED (t-94369a83 Phase 3a-1b, round C7b): every close test below now enters through
//  `LifecycleEntry.run(kind: .close)` -- the entry Cmd-W / the red button / Close Project use --
//  on the shared lifecycle harness (`LifecycleFlushHarness.withEntry`), with the fetch injected
//  through the harness's `getContent()` answer (nil = the fetch failed). The old entry,
//  `ContentView.performProjectClose(fetchContent:)` with its `flushAllPendingContent`, was the
//  UNKEYED (Getting Started) path until round C8b removed it. What the close does with the fetched text is the
//  save sequence (`EditorViewState.runLifecycleFlush`, plan section 4.2): F force-sends the
//  editor, step 5 fetches fresh content (a failed fetch falls back to `editorState.content`),
//  and step 6 (FB) writes that text through the writer's ordered queue, so every assertion
//  keeps its meaning and each test additionally asserts the guard path ran (the `.armed(.close)`
//  event, coder obligation 32).
//
//  Test (c) covers a related bug found while fixing this:
//  ContentView.fetchContentFromWebView's "2s timeout" used a withTaskGroup whose
//  evaluateJavaScript child is a withCheckedContinuation that group.cancelAll()
//  cannot resume -- so if WebKit never calls back, the timeout never actually let
//  the function return. The fix was the shared raceAgainstTimeout(_:_:) helper
//  (Services/TimeoutRace.swift), the same one BlockSyncService.fetchContentFromWebView
//  itself was migrated to (t-027c3835, quitting-can-hang-if-the-editor-stops-responding)
//  after this test first exposed the pattern. It is a pure helper test; since round C8b it
//  drives the helper directly (ContentView's own wrapper around it went with its last caller).
//

import Testing
import Foundation
@testable import final_final

/// Parks a continuation until `open()` is called -- stands in for a WebKit
/// `evaluateJavaScript` callback that never arrives. File-level (not nested in the suite) to stay within
/// SwiftLint's nesting limit, now that the suite itself lives inside `LifecycleEntryStatic`.
@MainActor
private final class CloseStaleTestGate {
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

extension LifecycleEntryStatic {

    @Suite("Project close vs stale content — Tier 1 (t-94369a83 3a-1b C7b)", .serialized, .timeLimit(.minutes(1)))
    @MainActor
    struct ProjectCloseStaleContentTests {

        // MARK: - Fixtures

        /// The document as the poll drain saved it -- what's already in the database by
        /// the time the close's save runs.
        private let settled = "# Close Project\n\nSettled paragraph."

        /// The real, most-recent edit -- what a live WebView fetch would return if the
        /// last JS -> Swift push had actually landed.
        private let fresh = "# Close Project\n\nSettled paragraph, PLUS last keystrokes."

        /// A rig on a project whose database holds `dbContent`, whose `editorState.content` is `editorContent`
        /// and whose editor answers `fetch` to `getContent()` (nil = the fetch fails). The scripted poll answers
        /// leave F with nothing pending, so only the fetch can carry text into the database.
        private func makeRig(dbContent: String, editorContent: String, fetch: String?) throws -> LifecycleFlushHarness {
            let rig = try LifecycleFlushHarness(content: dbContent)
            rig.editorState.content = editorContent
            rig.js.answer("flushPendingBlockChanges", true)
            rig.fetchAnswer = fetch
            return rig
        }

        /// Closes through the real entry: the save sequence, then `perform` (nothing to do here), then the tail.
        private func close(_ rig: LifecycleFlushHarness) async throws -> LifecycleRunOutcome? {
            var outcome: LifecycleRunOutcome?
            try await rig.withEntry {
                outcome = try await LifecycleEntry.run(kind: .close) { .close }
            }
            return outcome
        }

        /// Assemble the DB's current block content back into markdown, the same way
        /// ContentView.loadInitialContent does when a project opens.
        private func assembledDatabaseContent(from db: ProjectDatabase) throws -> String {
            let blocks = try TestFixtureFactory.fetchBlocks(from: db)
            return BlockParser.assembleMarkdownForEditor(from: blocks)
        }

        // MARK: - (a) Real regression assertion -- drives the close itself

        @Test("close does not overwrite a drained edit with a stale editorState.content copy")
        func closeDoesNotOverwriteDrainedEditWithStaleCopy() async throws {
            // The database already holds the edit the poll drain saved -- the REAL, most-recent content.
            // editorState.content is the STALE copy: the last JS -> Swift push was dropped mid-rebuild/
            // zoom/heading-fix, so it never caught up to what the drain already wrote.
            // `fetch` stands in for a live WebView reply -- the fresh, real content.
            let rig = try makeRig(dbContent: fresh, editorContent: settled, fetch: fresh)

            let outcome = try await close(rig)

            #expect(rig.entryEvents.first == .armed(.close), "the guard path ran (item 32)")
            #expect(outcome == .performed)
            let dbContent = try assembledDatabaseContent(from: rig.db)
            #expect(
                dbContent.contains("PLUS last keystrokes"),
                "close must not overwrite the drain's real edit with stale editorState.content"
            )
        }

        // MARK: - (a2) Real regression assertion -- the fetch is used even when the DB agrees

        @Test("close writes the fetched content even when the database already matches editorState.content")
        func closeWritesFetchedContentWhenEditorAndDatabaseAlreadyAgree() async throws {
            // A7 (review round 2): test (a) above seeds the DB with `fresh` AND has the fetch
            // return `fresh`, so it would still pass even if the close wrote nothing at all. Here the DB
            // and editorState.content start out agreeing (both `settled` -- "the keystrokes still inside
            // the 50ms debounce" case, not a drain-vs-stale race), and only the fetch carries the newer
            // text, so the assertion below can only pass if the fetched content was actually written.
            let rig = try makeRig(dbContent: settled, editorContent: settled, fetch: fresh)

            let outcome = try await close(rig)

            #expect(rig.entryEvents.first == .armed(.close), "the guard path ran (item 32)")
            #expect(outcome == .performed)
            let dbContent = try assembledDatabaseContent(from: rig.db)
            #expect(
                dbContent.contains("PLUS last keystrokes"),
                "close must write the fetched content, not just leave the DB's already-settled copy in place"
            )
        }

        // MARK: - (b) Regression guard -- fetch failure falls back to editorState.content

        @Test("close falls back to editorState.content (not the database's older copy) when the WebView fetch fails")
        func closeFallsBackWhenFetchFails() async throws {
            // A8 (review round 2): the DB is seeded with the OLDER `settled` text -- standing in for
            // whatever the database happened to hold before close began -- while editorState.content
            // holds the NEWER `fresh` text, the same way it would if the last JS -> Swift push landed
            // normally but the fetch (the one this test exercises failing) simply couldn't reach the
            // WebView. Seeding both with the SAME text would make the assertion below pass even if the
            // fallback write never ran at all.
            let rig = try makeRig(dbContent: settled, editorContent: fresh, fetch: nil)

            let outcome = try await close(rig)

            #expect(rig.entryEvents.first == .armed(.close), "the guard path ran (item 32)")
            #expect(outcome == .performed)
            #expect(rig.log.contains("fetch"), "the fetch was attempted (and answered nothing)")
            let dbContent = try assembledDatabaseContent(from: rig.db)
            #expect(
                dbContent.contains("PLUS last keystrokes"),
                "a failed fetch must fall back to editorState.content (the newer text), not leave the database's older copy in place"
            )
        }

        // MARK: - (c) the shared timeout race is real, not group-joined

        // CHANGED ENTRY (round C8b): `ContentView.raceContentFetch`, a thin wrapper over `raceAgainstTimeout`, went with
        // the old close/switch flush it served (`flushAllPendingContent` and `fetchContentFromWebView` had no caller left).
        // The assertion is unchanged and now drives the shared primitive itself.
        @Test("raceAgainstTimeout actually returns at the timeout, not when the raced work finally finishes")
        func raceAgainstTimeoutIsReal() async throws {
            let gate = CloseStaleTestGate()
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
            let outcome = await raceAgainstTimeout(.milliseconds(300)) { () -> String in
                await gate.wait()
                return "late"
            }
            let elapsed = clock.now - start

            if case .finished = outcome {
                Issue.record("the timeout must win when the raced work never finishes in time")
            }
            #expect(
                elapsed < .seconds(2),
                "raceAgainstTimeout must return at the timeout, not join the still-running raced work"
            )

            gate.open()
        }

        // MARK: - (d) A1 -- closing while zoomed must not delete Section rows outside the zoom

        /// Regression test for review round 2's A1: while zoomed, the content a close writes is only the zoomed
        /// subset's markdown. Without the zoom guard on the section-sync step (step 6b of the save sequence,
        /// `capture.zoomedSectionId == nil`), reconciling that subset's headers alone against EVERY `Section` row
        /// in the project makes `SectionReconciler.reconcile`'s delete sweep treat every row outside the zoom as
        /// unmatched and hard-delete it. The section service is ATTACHED to the editor state here, so a missing
        /// guard would really reach it.
        @Test("closing while zoomed does not delete the Section row outside the zoom")
        func closeWhileZoomedPreservesSectionOutsideZoom() async throws {
            let twoSectionContent = "# Section A\n\nContent A.\n\n# Section B\n\nContent B.\n"
            let zoomedContent = "# Section A\n\nContent A, PLUS last keystrokes.\n"
            let rig = try makeRig(dbContent: twoSectionContent, editorContent: twoSectionContent, fetch: zoomedContent)

            // The bare fixture only seeds Block rows, not Section rows -- those are normally populated by
            // configureForCurrentProject()'s own `sectionSyncService.syncNow(editorState.content)` call on
            // project open. Reproduce that so both sections actually exist as Section rows before the close.
            let sectionSync = SectionSyncService()
            sectionSync.configure(database: rig.db, projectId: rig.pid)
            sectionSync.editorState = rig.editorState
            rig.editorState.sectionSyncService = sectionSync
            await sectionSync.syncNow(twoSectionContent)

            let sectionsBeforeClose = try rig.db.fetchSections(projectId: rig.pid)
            #expect(sectionsBeforeClose.count == 2)
            _ = try #require(sectionsBeforeClose.first { $0.title == "Section A" })
            let sectionB = try #require(sectionsBeforeClose.first { $0.title == "Section B" })
            let alpha = try #require(try rig.blocks().first { $0.blockType == .heading && $0.textContent == "Section A" })
            let beta = try #require(try rig.blocks().first { $0.blockType == .heading && $0.textContent == "Section B" })

            // Zoom into Section A. While zoomed, editorState.content (and a live WebView fetch) only ever
            // holds the zoomed subset's markdown -- Section B is simply absent from it, not because the user
            // touched it. (FB anchors the zoomed write on the zoom's heading BLOCK, `alpha`, and its block range.)
            rig.editorState.zoomedSectionId = alpha.id
            rig.editorState.zoomedBlockRange = (start: alpha.sortOrder, end: beta.sortOrder)
            rig.editorState.content = zoomedContent

            let outcome = try await close(rig)

            #expect(rig.entryEvents.first == .armed(.close), "the guard path ran (item 32)")
            #expect(outcome == .performed)
            let sectionsAfterClose = try rig.db.fetchSections(projectId: rig.pid)
            #expect(
                sectionsAfterClose.contains { $0.id == sectionB.id },
                "closing while zoomed must not delete the Section row outside the zoom (\(sectionsAfterClose.map(\.title)))"
            )
            withExtendedLifetime(sectionSync) {}
        }

        // MARK: - (e) A9 -- close with a pending bibliography rebuild uses the fetched content

        /// Regression test for review round 2's A9: a bibliography update pending when the user closes must not
        /// clobber the fetched content with the stale `editorState.content`. Markdown mode, because that is the
        /// only mode whose bibliography update flushes the live editor text into the blocks
        /// (`ContentView.makeBibliographyFlushHandler`). The REAL hook is wired here (it is static now, so a test
        /// no longer mirrors its guards). What this pins is the outcome only: after the close, the blocks hold the
        /// fetched text, not the stale copy. The hook's lifecycle behaviour (N50) is pinned in
        /// `LifecycleRebuildDeferralTests`, not here.
        @Test("close with a pending bibliography rebuild writes the fetched content, not stale editorState.content")
        func closeWithPendingBibliographyRebuildUsesFetchedContent() async throws {
            let staleContent = "# Close Project\n\nSee reference [@closebibkey2026] here for details."
            let fetchedContent = "# Close Project\n\nSee reference [@closebibkey2026] here for details, PLUS last keystrokes."
            let rig = try makeRig(dbContent: staleContent, editorContent: staleContent, fetch: fetchedContent)
            rig.editorState.editorMode = .source

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

            let bibliography = rig.attachBibliographyService()
            bibliography.flushLiveEditorContentToBlocks = ContentView.makeBibliographyFlushHandler(for: rig.editorState)

            // Schedule the pending rebuild -- the bibliography debounce is in flight ("pending", not yet
            // fired) exactly as it would be if a citation was inserted just before the user closed the project.
            let citekeys = BibliographySyncService.extractCitekeys(from: staleContent)
            bibliography.checkAndUpdateBibliography(currentCitekeys: citekeys, projectId: rig.pid)

            let outcome = try await close(rig)

            #expect(rig.entryEvents.first == .armed(.close), "the guard path ran (item 32)")
            #expect(outcome == .performed)
            let blocksAfter = try TestFixtureFactory.fetchBlocks(from: rig.db)
            let nonBibBlocks = blocksAfter.filter { !$0.isBibliography }
            let assembled = BlockParser.assembleMarkdown(from: nonBibBlocks)
            #expect(
                assembled.contains("PLUS last keystrokes"),
                "close's pending-bibliography-rebuild must leave the fetched content in place, not stale editorState.content"
            )
            withExtendedLifetime(bibliography) {}
        }
    }
}
