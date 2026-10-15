//
//  ProjectSwitchStaleContentPushTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Regression test for documents opening blank/unstyled during a PROJECT SWITCH --
//  distinct from commit 47f238dc, which only fixed a File -> Open mount-timing race.
//
//  Mechanism (confirmed from a live diagnostic-log repro, 2026-08-28): closing a
//  project kicks off an async "flush pending edits before switch"
//  (ContentView.flushAllPendingContent) that can complete AFTER the new project has
//  already opened on the same live, already-mounted WebView (project switches reuse
//  the WebView -- no fresh mount, so 47f238dc's mount-readiness gate never engages
//  here). The old flushAllPendingContent assigned the fetched content straight to
//  `editorState.content`, a SwiftUI published property. That publish reaches
//  MilkdownEditor.updateNSView, whose only mid-switch guard (`isResettingContent`)
//  is still false at that point in handleProjectOpened(), so it fires a plain
//  setContent() of the OLD project's document into the view now representing the
//  NEW one. The document model self-corrects moments later, but the pane stays
//  visibly blank until something forces a repaint.
//
//  Fix: EditorViewState.flushContentToDatabase gained an `overrideContent` parameter,
//  and ContentView.flushAllPendingContent now threads the freshly-fetched content
//  through every consumer (the emptiness guard, the block re-parse, the section
//  sync, the annotation sync) WITHOUT ever assigning it to `editorState.content`.
//  `flushAllPendingContent` also gained an injected `fetchContent` parameter (mirrors
//  EditorViewState.flushLiveContentToDatabase's `currentContent` parameter) and internal
//  (not private) visibility, specifically so test (a) below can drive the REAL call site
//  with a stubbed fetch instead of only exercising flushContentToDatabase(overrideContent:)
//  in isolation -- see that test's own comment for why the isolated version alone was
//  insufficient (review round 1 must-fix 2).
//
//  Review round 1 found a second, related bug in the fix above: handleProjectOpened()
//  calls flushPendingBibliographyAndFootnoteSync() immediately after flushAllPendingContent(),
//  and a pending bibliography update's own flush hook (ContentView+ProjectLifecycle.swift's
//  makeBibliographyFlushHandler) used to read editorState.content directly -- which this
//  fix deliberately leaves stale during that exact window -- clobbering the fresh blocks
//  flushAllPendingContent() just wrote with a second, stale replaceBlocks. Closed by
//  threading the SAME fetched content through as an `overrideContent` argument all the way
//  down to that hook. See BibliographySourceModeFlushTests.swift's
//  overrideContentWinsOverStaleEditorStateContent test for the regression test covering
//  that specific fix.
//
//  PORTED (t-94369a83 Phase 3a-1b, round C7b): tests (a) and (d) used to drive
//  `ContentView.flushAllPendingContent(fetchContent:)`, the old project-switch flush, which is the unkeyed
//  (Getting Started) path only now. They live on, with the same assertions, at the bottom of this file in
//  `ProjectSwitchSaveStaleContentTests`, entering through the lifecycle save sequence a switch runs
//  (`LifecycleFlushHarness.run(.projectSwitch)`: `EditorViewState.runLifecycleFlush`, plan section 4.2, the part
//  of `LifecycleEntry.run(.projectSwitch)` before `perform`) with the fetch injected as the editor's
//  `getContent()` answer. Two things changed MEANING there on purpose, see that suite. Tests (a2), (b), (c), (e)
//  and (f) do not call an entry point and are untouched.
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite(.serialized)
struct ProjectSwitchStaleContentPushTests {

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: "/tmp/claude/ProjectSwitchStaleContentPushTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        TestFixtureCleanup.register(dir)
        return dir
    }

    /// Content standing in for the OLD project's settled document -- already matches
    /// what's in the DB fixture, exactly like `editorState.content` would at the moment
    /// a project switch begins (before any fetch has occurred).
    private let staleOldProjectContent = "# Old Project\n\nThis is the old project's settled content."

    /// Content standing in for what a live WebView fetch returns mid-switch -- an edit
    /// still sitting inside the JS 50ms debounce window when the switch began.
    private let freshFetchedContent = "# Old Project\n\nThis is the old project's settled content, PLUS an in-flight edit."

    /// Seed a fixture with `staleOldProjectContent`, then construct an `EditorViewState`
    /// wired to the same DB/project whose `content` also holds that same stale value --
    /// mirroring the exact moment a project switch's flush begins running: before any
    /// fetch, `editorState.content` and the DB agree.
    @MainActor
    private func makeFixture(in dir: URL, name: String) throws -> (db: ProjectDatabase, editorState: EditorViewState) {
        let fixtureURL = dir.appendingPathComponent("\(name).ff")
        let db = try TestFixtureFactory.createFixture(at: fixtureURL, title: name, content: staleOldProjectContent)
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        let editorState = EditorViewState()
        editorState.projectDatabase = db
        editorState.currentProjectId = projectId
        editorState.content = staleOldProjectContent

        return (db, editorState)
    }

    /// Assemble the DB's current block content back into markdown, the same way
    /// `ContentView.loadInitialContent` does when a project opens.
    private func assembledDatabaseContent(from db: ProjectDatabase) throws -> String {
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        return BlockParser.assembleMarkdownForEditor(from: blocks)
    }

    // MARK: - (a) moved: see `ProjectSwitchSaveStaleContentTests` below (ported onto the switch's save sequence)

    // MARK: - (a2) Narrower, direct unit test of the override parameter alone

    @Test("flushContentToDatabase(overrideContent:) persists the override to the database but does NOT publish it to editorState.content")
    @MainActor
    func overrideContentPersistsToDatabaseWithoutPublishingToEditorState() async throws {
        let dir = try makeTempDir()

        let (db, editorState) = try makeFixture(in: dir, name: "OverrideContentNoPublish")
        defer {
            editorState.projectDatabase = nil
            TestDatabaseTeardown.closeThenCleanUp(dir, db)
        }

        // Simulates what a project-switch flush does: pass the freshly fetched (possibly
        // belonging-to-a-project-mid-switch) content straight into flushContentToDatabase's
        // overrideContent parameter, WITHOUT touching editorState.content first (the old
        // code's `editorState.content = freshContent` is exactly the assignment this fix removes).
        //
        // NOTE (review round 1 must-fix 2): this test alone is NOT the regression test --
        // `flushContentToDatabase` never read or wrote `editorState.content` even before
        // this fix (it only ever read `content` when `overrideContent` was nil), so it
        // cannot detect a reintroduction of the actual regression, which lived inside the
        // switch's flush, not here. It pins a real, narrower invariant of the override
        // parameter itself; see `ProjectSwitchSaveStaleContentTests` at the bottom of this
        // file for the test that drives the real switch entry (the lifecycle save sequence).
        editorState.flushContentToDatabase(overrideContent: freshFetchedContent)

        // The database must reflect the override -- this is the real content that must
        // not be lost.
        let dbContent = try assembledDatabaseContent(from: db)
        #expect(
            dbContent.contains("PLUS an in-flight edit"),
            "Expected the override content to be persisted to the database"
        )

        #expect(
            editorState.content == staleOldProjectContent,
            "flushContentToDatabase(overrideContent:) must never touch editorState.content"
        )
    }

    // MARK: - (b) Sibling tripwire

    @Test("flushLiveContentToDatabase (the sibling used by export/snapshot/auto-backup) still publishes fetched content to editorState.content")
    @MainActor
    func liveFlushSiblingPublishesAndIsUnsafeForProjectSwitch() async throws {
        let dir = try makeTempDir()

        let (db, editorState) = try makeFixture(in: dir, name: "LiveFlushSiblingPublishes")
        defer {
            editorState.projectDatabase = nil
            TestDatabaseTeardown.closeThenCleanUp(dir, db)
        }

        await editorState.flushLiveContentToDatabase { freshFetchedContent }

        // ROUTING TRIPWIRE, not a desired invariant. This does not assert that publishing
        // here is *good* -- it asserts that this sibling still behaves the way the
        // project-switch path assumes it behaves. The export/snapshot/auto-backup callers
        // currently want the publish (the editor stays open and must show the flushed text);
        // the project-switch path must never have it.
        //
        // If you are deliberately changing flushLiveContentToDatabase to stop publishing,
        // this test failing is EXPECTED and correct: update it, and at the same time
        // re-check whether the project-switch flush should now route through this method
        // after all. Do NOT "fix" this by routing the project-switch path through
        // flushLiveContentToDatabase while it still publishes -- that is precisely the
        // regression (documents opening blank during a project switch) this suite exists
        // to prevent.
        #expect(
            editorState.content == freshFetchedContent,
            """
            flushLiveContentToDatabase is expected to publish fetched content to editorState.content \
            -- this is why it must never back the project-switch flush
            """
        )

        let dbContent = try assembledDatabaseContent(from: db)
        #expect(dbContent.contains("PLUS an in-flight edit"))
    }

    // MARK: - (c) removed (round C8b)
    //
    // `contentToFlushOnProjectSwitch(fetched:current:)`, the pure helper test (c) pinned, went with the old project-switch
    // flush (`flushAllPendingContent`), which had no caller left. Its "an EMPTY fetch falls back to the current content"
    // rule was deliberately replaced by the save sequence's own (an empty fetch is a valid answer: select all, delete,
    // close; a nil or timed-out fetch falls back to `editorState.content`), which `LifecycleFlushSequenceTests` pins.

    // MARK: - (d) moved: see `ProjectSwitchSaveStaleContentTests` below (ported onto the switch's save sequence)

    // MARK: - (e) Round 4: the suppression window is CHECKED, not consumed
    // (verification review finding 1 / judge round 3 must-fix 1)
    //
    // Separate mechanism from (a)-(d) above -- this covers `.bibliographySectionChanged`
    // notification timing during a project switch, not the content-invariant push. See
    // `EditorViewState.suppressBibliographyRebuildsDuringSwitch`'s own doc comment for the
    // full mechanism: round 3 armed this flag at the top of `handleProjectOpened()` but left
    // it a ONE-SHOT flag that `handleBibliographySectionChanged()` cleared on its own first
    // check -- protecting only the first of possibly two mid-switch
    // `.bibliographySectionChanged` posts (the explicit `flushPendingSync` call and the old
    // project's independently-firing debounce timer) and leaving the second free to reopen
    // the blank-pane publish window via its own unstructured Task's `isResettingContent`
    // writes.
    //
    // Round 4.1: the flag itself moved from a `@State Bool` on `ContentView` to a plain
    // stored property on `EditorViewState` -- the ORIGINAL version of this test set
    // `view.editorState.suppressBibliographyRebuildsDuringSwitch = true` directly on a bare,
    // directly-constructed `ContentView()` and failed, because that `ContentView` is never
    // installed into a real SwiftUI view graph, so `@State`'s `nonmutating set` has no
    // backing storage location to write to and silently no-ops: the write was never observed
    // by `handleBibliographySectionChanged()`'s later read of the same property, which read
    // back the untouched default `false` and proceeded as if unsuppressed. Every other
    // property this window's fix touches (`isResettingContent`, `switchInProgressContent`)
    // already lived on `EditorViewState`, a plain `@Observable` class -- which is exactly why
    // THEIR mutations already worked reliably here while the `@State` one didn't.

    @Test("""
    handleBibliographySectionChanged treats the project-switch suppression as a WINDOW, not a \
    one-shot consumed flag -- two notifications during the same switch are BOTH suppressed
    """)
    @MainActor
    func bibliographyRebuildSuppressionIsAWindowNotAOneShotFlag() {
        let view = ContentView()
        view.editorState.content = "# Some Document\n\nBody text so the emptiness guard doesn't short-circuit first."
        view.editorState.contentState = .idle
        view.editorState.zoomedSectionId = nil
        view.editorState.suppressBibliographyRebuildsDuringSwitch = true

        // First notification during the switch window -- must be suppressed before it ever
        // reaches the synchronous state writes (contentState/isResettingContent) that precede
        // this handler's fire-and-forget Task.
        view.handleBibliographySectionChanged()
        #expect(
            view.editorState.contentState == .idle,
            "first mid-switch notification must not start a rebuild while the window is active"
        )
        #expect(
            view.editorState.isResettingContent == false,
            "first mid-switch notification must not touch isResettingContent while the window is active"
        )
        #expect(
            view.editorState.suppressBibliographyRebuildsDuringSwitch == true,
            """
            the window must NOT self-consume on its first check -- round 3's one-shot shape \
            cleared itself right here, which is exactly what left a SECOND mid-switch \
            notification unprotected
            """
        )

        // Second notification during the SAME switch window (e.g. the old project's own
        // debounced bibliography check firing after the explicit flush already posted one) --
        // must ALSO be suppressed. This is the case round 3 got wrong, and the one a one-shot
        // flag can never pass: it protects only whichever post arrives first.
        view.handleBibliographySectionChanged()
        #expect(
            view.editorState.contentState == .idle,
            "second notification in the same window must also not start a rebuild"
        )
        #expect(
            view.editorState.isResettingContent == false,
            """
            second notification must also not touch isResettingContent -- this is the actual \
            hazard under repair: an unprotected second post's own Task sets isResettingContent \
            true then false on a schedule handleProjectOpened() doesn't control, which can clear \
            it AFTER handleProjectOpened() sets it true, reopening the blank-pane publish window
            """
        )
        #expect(view.editorState.suppressBibliographyRebuildsDuringSwitch == true)
    }

    @Test("handleBibliographySectionChanged proceeds normally once the suppression window has closed")
    @MainActor
    func bibliographyRebuildProceedsOnceWindowIsClosed() {
        let view = ContentView()
        view.editorState.content = "# Some Document\n\nBody text so the emptiness guard doesn't short-circuit first."
        view.editorState.contentState = .idle
        view.editorState.zoomedSectionId = nil
        view.editorState.suppressBibliographyRebuildsDuringSwitch = false

        // Negative control for the test above: with the window closed, the same call must
        // proceed past the guard -- proving the guard actually gates real behavior rather
        // than being vacuously satisfied by some other early-return. The assignments below
        // happen synchronously, before this handler's fire-and-forget Task is even created,
        // so they're observable immediately with no need to await or configure a database.
        view.handleBibliographySectionChanged()
        #expect(view.editorState.contentState == .bibliographyUpdate)
        #expect(view.editorState.isResettingContent == true)
    }

    // MARK: - (f) Round 4: resetForProjectSwitch actually clears switchInProgressContent
    // (verification review finding 6 / judge round 3 must-fix 2 -- "the highest-value item")
    //
    // Nothing pinned this before round 4: delete the one `switchInProgressContent = nil`
    // line inside `resetForProjectSwitch()` and the whole suite stayed green, while every
    // subsequent flush for the rest of the app's lifetime would silently keep using the
    // FIRST switch's staged content forever, with zero warning.

    @Test("resetForProjectSwitch clears switchInProgressContent")
    @MainActor
    func resetForProjectSwitchClearsSwitchInProgressContent() {
        let editorState = EditorViewState()
        editorState.switchInProgressContent = "content staged by an in-flight project switch"

        editorState.resetForProjectSwitch()

        #expect(
            editorState.switchInProgressContent == nil,
            """
            resetForProjectSwitch must clear switchInProgressContent -- otherwise the NEXT \
            project's flushContentToDatabase(overrideContent: nil) calls would silently keep \
            reading THIS (now long-stale) switch's staged content forever, since nothing else \
            ever clears it
            """
        )
    }
}

// MARK: - (a) and (d), ported onto the switch's save sequence (round C7b)

extension LifecycleEntryStatic {

    /// What a project SWITCH's save does with the fetched text. `LifecycleFlushHarness.run(.projectSwitch)` is the
    /// part of `LifecycleEntry.run(kind: .projectSwitch)` before `perform`: the token armed, the sequence run, the
    /// barrier released, the token cleared. The fetch is injected as the editor's `getContent()` answer.
    @Suite("Project switch save vs stale content — Tier 1 (t-94369a83 3a-1b C7b)", .serialized, .timeLimit(.minutes(1)))
    @MainActor
    struct ProjectSwitchSaveStaleContentTests {

        /// Content standing in for the OLD project's settled document -- already matches what's in the DB fixture,
        /// exactly like `editorState.content` would at the moment a project switch begins (before any fetch).
        private let staleOldProjectContent = "# Old Project\n\nThis is the old project's settled content."

        /// Content standing in for what a live WebView fetch returns mid-switch -- an edit still sitting inside the
        /// JS 50ms debounce window when the switch began.
        private let freshFetchedContent = "# Old Project\n\nThis is the old project's settled content, PLUS an in-flight edit."

        private func makeRig(editorMode: EditorMode = .wysiwyg, fetch: String?) throws -> LifecycleFlushHarness {
            let rig = try LifecycleFlushHarness(content: staleOldProjectContent)
            rig.editorState.editorMode = editorMode
            rig.js.answer("flushPendingBlockChanges", true)
            rig.js.answer("hasBlockChanges", false)
            rig.fetchAnswer = fetch
            return rig
        }

        private func assembledDatabaseContent(from db: ProjectDatabase) throws -> String {
            BlockParser.assembleMarkdownForEditor(from: try TestFixtureFactory.fetchBlocks(from: db))
        }

        // MARK: (a) Real regression assertion -- drives the switch's save itself

        @Test("""
        the project-switch save persists fresh WebView content to the database but never publishes it to \
        editorState.content
        """)
        func switchSavePersistsWithoutPublishing() async throws {
            let rig = try makeRig(fetch: freshFetchedContent)

            // Drives the ACTUAL switch entry's save (the lifecycle sequence), not just
            // EditorViewState.flushContentToDatabase(overrideContent:) one layer beneath it -- see
            // `overrideContentPersistsToDatabaseWithoutPublishingToEditorState` above for why that narrower test
            // alone cannot catch a reintroduction of an `editorState.content = freshContent` assignment.
            let result = await rig.run(.projectSwitch)

            #expect(result.outcome == .flushed)
            #expect(result.fetchedContent == freshFetchedContent, "the save reports the fetched content it wrote")

            // The database must reflect the fetched content -- this is the real content that must not be lost.
            let dbContent = try assembledDatabaseContent(from: rig.db)
            #expect(
                dbContent.contains("PLUS an in-flight edit"),
                "Expected the fetched content to be persisted to the database"
            )

            // The regression assertion: editorState.content must remain exactly what it was before the call. If
            // the save ever reintroduces an `editorState.content = ...` assignment, MilkdownEditor.updateNSView
            // (guarded only by isResettingContent, which is still false during a project switch's save) would push
            // it into whatever WebView is live at that moment -- which, mid-switch, already represents the NEW
            // project. See this file's header comment for the full mechanism.
            #expect(
                rig.editorState.content == staleOldProjectContent,
                """
                editorState.content must not be assigned by the switch's save -- an unrelated async route is not \
                observable at this assertion point either way, so this only pins the save's own behavior, which is \
                the confirmed root cause of documents opening blank during a project switch
                """
            )
        }

        // MARK: (d) staging switchInProgressContent, and nothing written when there is nothing to flush
        // (judge round 2, doc-open-blank-regression round 3, must-fix 1 + 2)

        /// The wiring half of the invariant fix: `EditorViewState.switchInProgressContent` only protects a caller that
        /// reaches `flushContentToDatabase(overrideContent: nil)` during a project switch if the switch's save
        /// actually stages it first. CHANGED MEANING, on purpose: the old `flushAllPendingContent` staged it in both
        /// modes; the lifecycle sequence stages it in MARKDOWN only (Rich Text stages nothing -- the only consumer is
        /// the Markdown bibliography flush hook, which now also stands down while a token is armed, N50), and an
        /// empty answer is staged as `""` on purpose (see `MarkdownLifecycleSourceTests`).
        @Test("""
        the switch's save stages the fetched content as switchInProgressContent in Markdown (so a mid-switch \
        flush with no override is protected) and stages nothing in Rich Text
        """)
        func switchSaveStagesSwitchInProgressContentInMarkdown() async throws {
            let markdown = try makeRig(editorMode: .source, fetch: freshFetchedContent)
            #expect(markdown.editorState.switchInProgressContent == nil, "precondition")

            let markdownResult = await markdown.run(.projectSwitch)

            #expect(markdownResult.outcome == .flushed)
            #expect(
                markdown.editorState.switchInProgressContent == freshFetchedContent,
                """
                the switch's save must stage the flushed content as switchInProgressContent -- this is what lets \
                flushContentToDatabase(overrideContent: nil) use it later, regardless of which caller reaches that \
                function with no explicit override (the invariant fix, not a per-caller patch)
                """
            )

            let richText = try makeRig(fetch: freshFetchedContent)
            _ = await richText.run(.projectSwitch)
            #expect(richText.editorState.switchInProgressContent == nil, "Rich Text stages nothing (changed on purpose)")
        }

        /// The empty-case half. The old flush returned nil (not "") when nothing was flushed, so a caller forwarding
        /// it as `overrideContent` fell back to reading content fresh at its own call time instead of being locked
        /// to an empty override. The sequence has no such return value to forward; what that guarantee protected is
        /// that an EMPTY document is never written over the project, which is what is pinned here: FB is skipped
        /// (an empty document is no write) and the database keeps what it had.
        @Test("the switch's save writes nothing when there is nothing to flush (no content, no fetch)")
        func switchSaveWithNothingToFlushWritesNothing() async throws {
            let rig = try makeRig(fetch: nil)
            rig.editorState.content = ""
            let before = try assembledDatabaseContent(from: rig.db)
            #expect(before.contains("settled content"), "precondition: the database holds the old project's text")

            let result = await rig.run(.projectSwitch)

            #expect(result.outcome == .flushed)
            #expect(result.fbStatus == .skippedEmptyContent, "an empty document is not a write")
            #expect(try assembledDatabaseContent(from: rig.db) == before, "the database must be left exactly as it was")
        }
    }
}
