//
//  LifecycleRebuildDeferralTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C4 (slice-3a-1b-everyday.md sections 4.2 and 5.3, coder obligation 23, N50):
//  what the rebuild handlers and the Markdown bibliography hook do while a close / project switch / quit holds
//  the editor (`activeLifecycle != nil`).
//
//    - the bibliography and Notes rebuild handlers and BOTH footnote-insertion handlers DEFER: the pending flag
//      or label is kept and nothing starts (no `contentState` change, no `isResettingContent`, no rebuild Task),
//      so no new rebuild runs inside the window. A cancelled lifecycle re-posts them (round C5a); a completed
//      one drops them (round C5b).
//    - the Markdown bibliography flush hook returns SILENTLY while armed, before its `flushContentToDatabase`
//      (N50): it neither writes, nor asserts, nor reports. Step 7's own bibliography refresh reaches it on every
//      Markdown close that cites a source, so a close with a pending bibliography update must complete in DEBUG
//      with no assertion.
//
//  The handlers are driven on a bare `ContentView()` (the repo's existing technique). The deferred state lives
//  on `EditorViewState` rather than in `ContentView` `@State`, which a bare view silently drops.
//

import Foundation
import Testing
@testable import final_final

/// Records what the real hook did when step 7 reached it.
@MainActor
private final class HookProbe {
    var invocations = 0
    var idsBefore: [String] = []
    var idsAfter: [String] = []
}

@Suite("Lifecycle rebuild deferral and the Markdown bibliography hook — Tier 1 (t-94369a83 3a-1b C4)", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct LifecycleRebuildDeferralTests {

    private static let seed = "# Alpha\n\none two three.\n\n# Beta\n\nfour five six.\n"

    private func arm(_ editorState: EditorViewState, sourceLocation: SourceLocation = #_sourceLocation) -> LifecycleToken? {
        guard case .armed(let token) = editorState.armLifecycle(.close, wasGettingStarted: false) else {
            Issue.record("could not arm a close token", sourceLocation: sourceLocation)
            return nil
        }
        return token
    }

    /// Nothing started: no content-state change, no reset flag, no rebuild Task.
    private func expectNothingStarted(_ editorState: EditorViewState, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(editorState.contentState == .idle, "no rebuild may flip the content state", sourceLocation: sourceLocation)
        #expect(!editorState.isResettingContent, "no rebuild may start resetting the editor", sourceLocation: sourceLocation)
        #expect(editorState.runningRebuildTasks.isEmpty, "no rebuild Task may be started", sourceLocation: sourceLocation)
    }

    // MARK: - The handlers

    @Test("the bibliography rebuild handler DEFERS while armed: the flag is kept and nothing starts")
    func bibliographyHandler_whileArmed_defers() throws {
        let view = ContentView()
        let editorState = view.editorState
        editorState.content = "Some body text citing prior work."
        editorState.contentState = .idle
        _ = try #require(arm(editorState))

        view.handleBibliographySectionChanged()

        #expect(editorState.pendingBibliographyRebuild, "the request is kept, not dropped")
        #expect(!editorState.pendingNotesRebuild)
        #expect(editorState.pendingFootnoteLabels.isEmpty)
        expectNothingStarted(editorState)
    }

    @Test("the Notes rebuild handler DEFERS while armed: the flag is kept and nothing starts")
    func notesHandler_whileArmed_defers() throws {
        let view = ContentView()
        let editorState = view.editorState
        editorState.content = "Some body text with a footnote[^1]."
        editorState.contentState = .idle
        _ = try #require(arm(editorState))

        view.handleNotesSectionChanged()

        #expect(editorState.pendingNotesRebuild, "the request is kept, not dropped")
        #expect(!editorState.pendingBibliographyRebuild)
        expectNothingStarted(editorState)
    }

    @Test("the footnote-insertion handler DEFERS while armed: the label is kept and nothing starts")
    func footnoteHandler_whileArmed_keepsTheLabel() throws {
        let view = ContentView()
        let editorState = view.editorState
        editorState.contentState = .idle
        _ = try #require(arm(editorState))

        view.handleFootnoteInsertedImmediate(
            Notification(name: .footnoteInsertedImmediate, object: nil, userInfo: ["label": "7"]))

        let kept = editorState.pendingFootnoteLabels.dequeue()
        #expect(kept == "7", "the label must be queued for the lifecycle's end")
        #expect(editorState.pendingFootnoteLabels.isEmpty)
        expectNothingStarted(editorState)
    }

    @Test("the footnote-insertion handler DEFERS while armed even when zoomed: it must not route to the zoom path")
    func footnoteHandler_whileArmedAndZoomed_keepsTheLabel() throws {
        let view = ContentView()
        let editorState = view.editorState
        editorState.contentState = .idle
        editorState.zoomedSectionId = "some-zoom-root"
        _ = try #require(arm(editorState))

        view.handleFootnoteInsertedImmediate(
            Notification(name: .footnoteInsertedImmediate, object: nil, userInfo: ["label": "8"]))

        let kept = editorState.pendingFootnoteLabels.dequeue()
        #expect(kept == "8")
        expectNothingStarted(editorState)
    }

    @Test("the zoomed footnote insertion DEFERS while armed: the label is kept and nothing starts")
    func zoomedFootnoteInsertion_whileArmed_keepsTheLabel() throws {
        let view = ContentView()
        let editorState = view.editorState
        editorState.contentState = .idle
        editorState.zoomedSectionId = "some-zoom-root"
        _ = try #require(arm(editorState))

        view.handleZoomedFootnoteInsertion(label: "9", projectId: "some-project")

        let kept = editorState.pendingFootnoteLabels.dequeue()
        #expect(kept == "9")
        expectNothingStarted(editorState)
    }

    // MARK: - The Markdown bibliography hook (N50)

    private func blockIdentities(_ db: ProjectDatabase) throws -> [String] {
        try TestFixtureFactory.fetchBlocks(from: db).map { "\($0.id)|\($0.textContent)" }
    }

    @Test("""
        N50: the real Markdown bibliography flush hook returns SILENTLY while armed -- it replaces nothing, with or \
        without an override -- and flushes again once the lifecycle is over (control)
        """)
    func bibliographyHook_whileArmed_returnsWithoutFlushing() async throws {
        let db = try TestFixtureFactory.createTemporary(content: Self.seed)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let editorState = EditorViewState()
        editorState.projectDatabase = db
        editorState.currentProjectId = pid
        editorState.editorMode = .source
        editorState.content = "# Alpha\n\nSTALE hook text that must not be written.\n\n# Beta\n\nfour five six.\n"
        let hook = ContentView.makeBibliographyFlushHandler(for: editorState)
        let before = try blockIdentities(db)

        let token = try #require(arm(editorState))
        await hook(pid, nil)
        await hook(pid, "# Alpha\n\nOVERRIDE text.\n\n# Beta\n\nfour five six.\n")
        #expect(try blockIdentities(db) == before, "an armed hook must not touch the block table at all")

        // Control: the same call once the lifecycle is over DOES flush.
        editorState.clearLifecycle(token.id)
        await hook(pid, "# Alpha\n\nOVERRIDE text.\n\n# Beta\n\nfour five six.\n")
        let texts = try TestFixtureFactory.fetchBlocks(from: db).filter { $0.blockType == .paragraph }.map(\.textContent)
        #expect(texts.contains("OVERRIDE text."), "control: an unarmed hook writes; got \(texts)")
    }

    @Test("""
        N50: a Markdown close with a pending bibliography update completes with no assertion: step 7's \
        bibliography refresh reaches the REAL hook, and the hook replaces nothing
        """)
    func markdownClose_withPendingBibliographyUpdate_hookSkipsSilently() async throws {
        let key = "lifecyclen50key2026"
        let rig = try LifecycleFlushHarness()
        rig.editorState.editorMode = .source
        let bibliography = rig.attachBibliographyService()
        let real = ContentView.makeBibliographyFlushHandler(for: rig.editorState)
        let probe = HookProbe()
        bibliography.flushLiveEditorContentToBlocks = { projectId, overrideContent in
            probe.invocations += 1
            probe.idsBefore = (try? rig.blocks().map(\.id)) ?? []
            await real(projectId, overrideContent)
            probe.idsAfter = (try? rig.blocks().map(\.id)) ?? []
        }
        let itemJSON = """
        {"id":"\(key)","type":"book","title":"Lifecycle N50 Title",\
        "author":[{"family":"Quietfam","given":"Quinn"}],"issued":{"date-parts":[[2024]]}}
        """
        let item = try JSONDecoder().decode(CSLItem.self, from: Data(itemJSON.utf8))
        // `ZoteroService.shared` is process-global and other suites set it too, so this test leaves it as it found
        // it and does not clear the shared item cache (the item has a key of its own).
        let wasConnected = ZoteroService.shared.isConnected
        ZoteroService.shared.isConnected = true
        ZoteroService.shared.loadItem(item)
        defer { ZoteroService.shared.isConnected = wasConnected }
        let fresh = "# Alpha\n\nciting [@\(key)] here.\n\n# Beta\n\nfour five six.\n"
        rig.fetchAnswer = fresh
        // A bibliography update is pending when the close starts; step 0 suspends the service around it.
        bibliography.checkAndUpdateBibliography(currentCitekeys: [key], projectId: rig.pid)

        let result = await rig.run(.close)

        #expect(result.outcome == .flushed)
        #expect(result.bibliographyRefresh == .completed)
        #expect(probe.invocations >= 1, "non-vacuous: step 7's refresh must have reached the real hook")
        #expect(!probe.idsBefore.isEmpty)
        #expect(probe.idsBefore == probe.idsAfter, "the hook must not have replaced the block table: FB already wrote it")
        let texts = try rig.paragraphTexts()
        #expect(texts.contains { $0.contains("citing") }, "FB's text is in the database; got \(texts)")
        #expect(rig.sync.testWriterLedger.lifecycleWholeDocumentApplied == 1)
        bibliography.reset()
    }
}
