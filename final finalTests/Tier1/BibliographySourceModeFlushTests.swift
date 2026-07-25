//
//  BibliographySourceModeFlushTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//
//  Regression tests for the citation-revert-to-/cite bug: in Source Mode, the ONLY
//  writer of live editor text into the `block` table is a 1s-debounced full re-parse
//  (ViewNotificationModifiers.swift) whose fire-time guard silently drops the write if
//  content state isn't idle at that moment. BlockSyncService's force-flush (which the
//  bibliography rebuild path relies on in WYSIWYG) is a complete no-op in Source Mode --
//  its WebView is only ever assigned to the Milkdown editor. So a citation insert's
//  bibliography-section rebuild (also ~1s debounced) could read stale, still-/cite-
//  containing rows from the DB and push them back out, undoing the user's citation.
//
//  The fix: BibliographySyncService.flushLiveEditorContentToBlocks, a hook invoked at
//  the start of every bibliography update (BEFORE any bibliography row is written),
//  wired by ContentView+ProjectLifecycle.swift's configureForCurrentProject() to a
//  Source-Mode-only, project-identity-guarded call to
//  EditorViewState.flushContentToDatabase().
//
//  Follows BibliographySyncTests.swift's fixture + direct performBibliographyUpdate
//  drive pattern, and ExportFlushTests.swift's pattern of constructing a standalone
//  EditorViewState and wiring a hand-built closure that mirrors production wiring
//  exactly, since driving the real SwiftUI `.onChange(of:)` pipeline end-to-end isn't
//  reachable from a headless Tier1 test (no view hierarchy or render loop). Where a
//  test needs to simulate "the real onChange-triggered path," it reproduces the exact
//  production call sequence (extractCitekeys -> checkAndUpdateBibliography) from
//  ViewNotificationModifiers.swift's handleContentChange instead of hand-rolling a
//  weaker stand-in.
//
//  .serialized for the same reason as BibliographySyncTests.swift: several tests touch
//  ZoteroService.shared, a @MainActor singleton hardcoded (not injectable) by
//  performBibliographyUpdate.
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite("Bibliography Source-Mode Flush — Tier 1: Silent Killers", .serialized)
struct BibliographySourceModeFlushTests {

    /// Builds the exact closure ContentView+ProjectLifecycle.swift's
    /// configureForCurrentProject() wires onto `flushLiveEditorContentToBlocks`. Kept as
    /// a single shared helper so every test here exercises the identical guard sequence
    /// production uses, rather than N slightly-drifted copies.
    @MainActor
    private func productionFlushHook(
        editorState: EditorViewState,
        onInvoked: (() -> Void)? = nil,
        onExecuted: (() -> Void)? = nil
    ) -> (String) async -> Void {
        { [weak editorState] scheduledForProjectId in
            onInvoked?()
            guard let editorState, editorState.editorMode == .source else { return }
            guard editorState.currentProjectId == scheduledForProjectId else { return }
            onExecuted?()
            editorState.flushContentToDatabase()
        }
    }

    // MARK: - 1. Core regression test

    @Test("Citation insert survives the bibliography rebuild: DB reflects the resolved citation, not stale /cite, before the bibliography write")
    @MainActor
    func citationInsertSurvivesBibliographyRebuildInSourceMode() async throws {
        // DB starts with the STALE pre-resolution content -- modeling the real race: the
        // literal "/cite" text is what the 1s-debounced full re-parse
        // (ViewNotificationModifiers.swift) would eventually write, but it hasn't fired
        // yet when the bibliography debounce (also ~1s) fires first.
        let staleContent = "# Test Document\n\nSee reference /cite here for details."
        let db = try TestFixtureFactory.createTemporary(content: staleContent)
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        let itemJSON = """
        {"id":"flushcorekey2026","type":"book","title":"Flush Core Title","author":[{"family":"Corefam","given":"Cora"}],"issued":{"date-parts":[[2023]]}}
        """
        let item = try JSONDecoder().decode(CSLItem.self, from: Data(itemJSON.utf8))
        ZoteroService.shared.isConnected = true
        ZoteroService.shared.loadItem(item)
        defer {
            ZoteroService.shared.isConnected = false
            ZoteroService.shared.clearCache()
        }

        // The live editor's text ALREADY reflects the resolved citation by the time the
        // bibliography debounce fires -- CodeMirror resolves /cite -> [@key] synchronously
        // the instant the Zotero picker callback returns (citationPickerCallback in
        // web/codemirror/src/api.ts), well before either 1s debounce elapses. Only the DB
        // write of that resolved text is delayed -- that delay is Defect A.
        let freshContent = "# Test Document\n\nSee reference [@flushcorekey2026] here for details."

        let editorState = EditorViewState()
        editorState.projectDatabase = db
        editorState.currentProjectId = projectId
        editorState.editorMode = .source
        editorState.content = freshContent

        let service = BibliographySyncService()
        service.configure(database: db, projectId: projectId)
        service.flushLiveEditorContentToBlocks = productionFlushHook(editorState: editorState)

        // Drive the exact same production entry point ViewNotificationModifiers.swift's
        // handleContentChange calls (lines ~371-376), AFTER editorState.content has
        // already been updated to newValue -- exactly as SwiftUI's
        // .onChange(of: editorState.content) guarantees (newValue is bound to the
        // already-mutated property before the handler body runs). Driving the real
        // SwiftUI onChange pipeline itself isn't reachable here (no view hierarchy /
        // render loop in a headless Tier1 test), so this reproduces the production call
        // sequence directly rather than a weaker hand-rolled stand-in.
        let citekeys = BibliographySyncService.extractCitekeys(from: editorState.content)
        service.checkAndUpdateBibliography(currentCitekeys: citekeys, projectId: projectId)
        await service.flushPendingSync()

        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)
        let nonBibBlocks = blocksAfter.filter { !$0.isBibliography }
        let assembled = BlockParser.assembleMarkdown(from: nonBibBlocks)

        #expect(
            assembled.contains("[@flushcorekey2026]"),
            "Flush must have written the resolved citation into the block table"
        )
        #expect(!assembled.contains("/cite"), "The stale /cite text must not survive the flush")

        // Non-vacuous prefix check (flagged in review twice): confirm the flush captured
        // the FULL citation span, not merely up to where it starts. A flush that
        // truncated right at the citation's start offset (e.g. an off-by-one in the
        // re-parse) would still pass a weaker "prefix reaches the start" check while
        // silently corrupting everything after it.
        let citationRange = try #require(freshContent.range(of: "[@flushcorekey2026]"))
        let citationEndOffset = freshContent.distance(from: freshContent.startIndex, to: citationRange.upperBound)
        let commonPrefixLength = zip(freshContent, assembled).prefix(while: { $0 == $1 }).count
        #expect(
            commonPrefixLength >= citationEndOffset,
            """
            Common prefix between the live editor content (len \(freshContent.count)) and the \
            flushed/reassembled block markdown (len \(assembled.count)) must extend at least \
            through the citation's full span (offset \(citationEndOffset)), not stop at its \
            start; got \(commonPrefixLength)
            """
        )
    }

    // MARK: - 2. Ordering test: flush before write

    @Test("Flush runs before the bibliography write, not after (a post-write flush would clobber the fresh bibliography rows)")
    @MainActor
    func flushRunsBeforeNotAfterBibliographyWrite() async throws {
        // editorState.content deliberately has NO bibliography section -- it models the
        // live editor's text as CodeMirror has it before Swift ever pushes the newly
        // generated bibliography markdown back down (that push happens later, triggered
        // by the .bibliographySectionChanged notification this function posts at the
        // end). This is what makes the test ordering-sensitive: flushContentToDatabase()
        // does a wholesale delete-and-reinsert of every block for the project
        // (Database+BlocksReorder.swift's replaceBlocks deletes ALL rows for the project
        // before reinserting only what it re-parses from editorState.content). If the
        // flush ran AFTER the bibliography write instead of before, it would delete the
        // bibliography rows just written -- because they're not present in
        // editorState.content yet -- and this test would then fail.
        let staleContent = "# Test Document\n\nBody paragraph, no bibliography section yet."
        let db = try TestFixtureFactory.createTemporary(content: staleContent)
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        let itemJSON = """
        {"id":"orderguardkey2026","type":"book","title":"Order Guard Title","author":[{"family":"Ordertest","given":"Olive"}],"issued":{"date-parts":[[2024]]}}
        """
        let item = try JSONDecoder().decode(CSLItem.self, from: Data(itemJSON.utf8))
        ZoteroService.shared.isConnected = true
        ZoteroService.shared.loadItem(item)
        defer {
            ZoteroService.shared.isConnected = false
            ZoteroService.shared.clearCache()
        }

        let editorState = EditorViewState()
        editorState.projectDatabase = db
        editorState.currentProjectId = projectId
        editorState.editorMode = .source
        editorState.content = "# Test Document\n\nBody paragraph, citing [@orderguardkey2026] now."

        let service = BibliographySyncService()
        service.configure(database: db, projectId: projectId)
        service.flushLiveEditorContentToBlocks = productionFlushHook(editorState: editorState)

        service.checkAndUpdateBibliography(currentCitekeys: ["orderguardkey2026"], projectId: projectId)
        await service.flushPendingSync()

        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)
        let bibHeadings = blocksAfter.filter { $0.isBibliography && $0.blockType == .heading }
        let bibEntries = blocksAfter.filter { $0.isBibliography && $0.blockType != .heading }

        #expect(
            bibHeadings.count == 1,
            "Exactly one bibliography heading must survive -- a post-write flush would have deleted it"
        )
        #expect(
            bibEntries.contains { $0.markdownFragment.contains("Ordertest") },
            "The bibliography entry for the new citekey must survive the flush intact"
        )
    }

    // MARK: - 3. Hook nil (WYSIWYG unaffected)

    @Test("Bibliography rows are written exactly as before when no flush hook is wired at all")
    @MainActor
    func bibliographyWritesUnaffectedWhenHookIsNil() async throws {
        let db = try TestFixtureFactory.createTemporary(content: "Citing [@nohookkey2026] here.")
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        let itemJSON = """
        {"id":"nohookkey2026","type":"book","title":"No Hook Title","author":[{"family":"Nohook","given":"Nora"}],"issued":{"date-parts":[[2025]]}}
        """
        let item = try JSONDecoder().decode(CSLItem.self, from: Data(itemJSON.utf8))
        ZoteroService.shared.isConnected = true
        ZoteroService.shared.loadItem(item)
        defer {
            ZoteroService.shared.isConnected = false
            ZoteroService.shared.clearCache()
        }

        let service = BibliographySyncService()
        service.configure(database: db, projectId: projectId)
        // flushLiveEditorContentToBlocks intentionally left nil -- the bibliography write
        // path must need no hook at all to function correctly (matches today's behavior).
        #expect(service.flushLiveEditorContentToBlocks == nil)

        service.checkAndUpdateBibliography(currentCitekeys: ["nohookkey2026"], projectId: projectId)
        await service.flushPendingSync()

        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let bibBlocks = blocks.filter { $0.isBibliography }
        #expect(!bibBlocks.isEmpty, "Bibliography must still be written when no hook is wired")
        #expect(bibBlocks.contains { $0.markdownFragment.contains("Nohook") })
    }

    // MARK: - 4. Hook not invoked for a superseded generation

    @Test("The flush hook is never invoked for a stale, superseded scheduledGeneration")
    @MainActor
    func hookNotInvokedForStaleGeneration() async throws {
        let db = try TestFixtureFactory.createTemporary(content: "# Test Document\n\nNo citations yet.")
        let projectId = try TestFixtureFactory.getProjectId(from: db)
        // No Zotero item registration needed -- the generation guard must reject this
        // call before performBibliographyUpdate ever reaches the flush hook or Zotero.

        let service = BibliographySyncService()
        service.configure(database: db, projectId: projectId)

        var hookInvokedCount = 0
        service.flushLiveEditorContentToBlocks = { _ in hookInvokedCount += 1 }

        // Two racing calls, as in BibliographySyncTests.swift's
        // staleGenerationRejectedCurrentGenerationWrites: the first bumps syncGeneration
        // to 1, the second to 2, superseding the first.
        service.checkAndUpdateBibliography(currentCitekeys: ["staleGenKeyA"], projectId: projectId)
        service.checkAndUpdateBibliography(currentCitekeys: ["staleGenKeyB"], projectId: projectId)

        // The stale (generation 1) debounce fires late, carrying the superseded snapshot.
        await service.performBibliographyUpdate(
            citekeys: ["staleGenKeyA"], projectId: projectId, scheduledGeneration: 1
        )

        #expect(
            hookInvokedCount == 0,
            "A stale, superseded generation must be rejected before the flush hook ever runs"
        )
    }

    // MARK: - 5. Hook is a no-op when editorMode == .wysiwyg

    @Test("The wired flush hook is a no-op in WYSIWYG mode: bibliography still writes, but the flush itself never runs")
    @MainActor
    func hookNoOpInWysiwygMode() async throws {
        let db = try TestFixtureFactory.createTemporary(content: "# Doc\n\nStale paragraph, not touched by flush.")
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        let itemJSON = """
        {"id":"wysiwygguardkey2026","type":"book","title":"Wysiwyg Guard Title","author":[{"family":"Wysiwygfam","given":"Wendy"}],"issued":{"date-parts":[[2021]]}}
        """
        let item = try JSONDecoder().decode(CSLItem.self, from: Data(itemJSON.utf8))
        ZoteroService.shared.isConnected = true
        ZoteroService.shared.loadItem(item)
        defer {
            ZoteroService.shared.isConnected = false
            ZoteroService.shared.clearCache()
        }

        let editorState = EditorViewState()
        editorState.projectDatabase = db
        editorState.currentProjectId = projectId
        editorState.editorMode = .wysiwyg // <-- WYSIWYG, not Source
        editorState.content = "# Doc\n\nFresh content that should NEVER be flushed in WYSIWYG mode."

        let service = BibliographySyncService()
        service.configure(database: db, projectId: projectId)
        service.flushLiveEditorContentToBlocks = productionFlushHook(editorState: editorState)

        service.checkAndUpdateBibliography(currentCitekeys: ["wysiwygguardkey2026"], projectId: projectId)
        await service.flushPendingSync()

        // Bibliography must still be written -- the hook being skipped doesn't block the
        // bibliography feature itself. WYSIWYG relies on BlockSyncService's own polling
        // to keep non-bib blocks current, independent of this hook.
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        #expect(blocks.contains { $0.isBibliography })

        // But the flush must NOT have run: the stale paragraph from the original fixture
        // must still be present, and the "fresh" editor-only content must NOT appear --
        // proving flushContentToDatabase() (which re-parses editorState.content) never
        // fired for this update.
        let nonBib = blocks.filter { !$0.isBibliography }
        let assembled = BlockParser.assembleMarkdown(from: nonBib)
        #expect(assembled.contains("Stale paragraph, not touched by flush."))
        #expect(!assembled.contains("Fresh content that should NEVER be flushed in WYSIWYG mode."))
    }

    // MARK: - 6. Project-identity guard

    @Test("Project-identity guard skips the flush and avoids a cross-project write when the scheduled projectId no longer matches the live project")
    @MainActor
    func projectIdentityGuardSkipsFlushOnMismatch() async throws {
        let db = try TestFixtureFactory.createTemporary(content: "# Doc\n\nOriginal stale paragraph, must survive untouched.")
        let realProjectId = try TestFixtureFactory.getProjectId(from: db)

        let itemJSON = """
        {"id":"guardmismatchkey2026","type":"book","title":"Guard Mismatch Title","author":[{"family":"Guardfam","given":"Gina"}],"issued":{"date-parts":[[2022]]}}
        """
        let item = try JSONDecoder().decode(CSLItem.self, from: Data(itemJSON.utf8))
        ZoteroService.shared.isConnected = true
        ZoteroService.shared.loadItem(item)
        defer {
            ZoteroService.shared.isConnected = false
            ZoteroService.shared.clearCache()
        }

        let editorState = EditorViewState()
        editorState.projectDatabase = db
        editorState.currentProjectId = realProjectId
        editorState.editorMode = .source
        editorState.content = "# Doc\n\nFresh editor content that must never leak across the project boundary."

        let service = BibliographySyncService()
        service.configure(database: db, projectId: realProjectId)

        var hookInvokedCount = 0
        var flushExecutedCount = 0
        service.flushLiveEditorContentToBlocks = productionFlushHook(
            editorState: editorState,
            onInvoked: { hookInvokedCount += 1 },
            onExecuted: { flushExecutedCount += 1 }
        )

        // Simulate a project switch landing between schedule-time and fire-time: drive
        // performBibliographyUpdate directly (same direct-drive technique as
        // BibliographySyncTests.swift) with a projectId different from the live editor's
        // currentProjectId -- standing in for "this update was scheduled for the OLD
        // project, but a switch happened before it actually ran."
        let mismatchedScheduledProjectId = "mismatched-\(UUID().uuidString)"
        await service.performBibliographyUpdate(
            citekeys: ["guardmismatchkey2026"], projectId: mismatchedScheduledProjectId, scheduledGeneration: 0
        )

        #expect(
            hookInvokedCount == 1,
            "The flush hook should still be invoked once -- it's the hook's own job to check identity and bail"
        )
        #expect(flushExecutedCount == 0, "The flush must be skipped on a projectId mismatch")

        // The REAL project's blocks (filtered explicitly -- performBibliographyUpdate's
        // bibliography write above targeted the mismatched id, not this one) must remain
        // exactly as the fixture created them, proving no flush-driven write crossed the
        // project boundary.
        let realProjectBlocks = try TestFixtureFactory.fetchBlocks(from: db).filter { $0.projectId == realProjectId }
        let assembled = BlockParser.assembleMarkdown(from: realProjectBlocks)
        #expect(assembled.contains("Original stale paragraph, must survive untouched."))
        #expect(!assembled.contains("Fresh editor content that must never leak across the project boundary."))
    }
}
