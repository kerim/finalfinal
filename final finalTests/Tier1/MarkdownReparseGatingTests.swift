//
//  MarkdownReparseGatingTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C4, P5 (slice-3a-1b-everyday.md section 5.3, coder obligation 24): the
//  debounced Source Mode re-parse (`ContentSyncObserverHost.scheduleSourceModeReparse`, both the full-document
//  and the zoomed branch) used to be a DIRECT whole-document write outside the writer, with `db`/`pid` read at
//  schedule time. While a close / project switch / quit holds the editor it must not write:
//
//    - while armed it is not SCHEDULED at all;
//    - one scheduled BEFORE the lifecycle armed and firing inside the window does NOT write (the lifecycle's own
//      whole-document save carries the same text, and a write landing after it is what the queue prevents);
//    - at fire time it also re-checks that the editor is still on the project it was scheduled for.
//
//  Phase 4a (t-94369a83, plan v2 section 3 U3(a)): the FULL-DOCUMENT branch now saves block by block THROUGH the
//  ordered write queue (`MarkdownBlockWriter`) whenever the editor state has a block-sync writer, and falls back to
//  today's whole-document write (`legacyWholeDocumentReparse`) only when it has none (`.noWriter`). The gates are
//  unchanged, so every "does not write" test runs in BOTH arms, and each has a CONTROL whose write is proven to have
//  gone the way its arm says:
//
//    - writer arm:   the control's write went THROUGH the writer: the `[MdWrite]` line says `mode=rows ... outcome=applied`
//                    and the writer reserved exactly one sequence;
//    - fallback arm: the control's write is the legacy whole-document write: the line says `mode=legacy`.
//
//  and the "does not write" runs additionally show that nothing was reserved and no `[MdWrite]` line was produced.
//  The ZOOMED branch was untouched by Phase 4a; Phase 5 job A8 moved its write onto the queue too
//  (`MarkdownBlockWriter.writeZoomedNow`), behind the same fire-time gates: its control proves one sequence is reserved,
//  and the armed run reserves none.
//
//  Every "does not write" test has a CONTROL: the identical run, unarmed, DOES write. Without it a test that
//  merely never reached the write would pass.
//
//  The debounce (one second in the app) is shortened per editor state (`sourceReparseDebounce`), and the tests
//  await the re-parse Task itself (and, in the writer arm, the write it started) rather than sleeping.
//

import Foundation
import SwiftUI
import Testing
import WebKit
@testable import final_final

@Suite("Markdown re-parse gating (P5) — Tier 1 (t-94369a83 3a-1b C4, Phase 4a)", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct MarkdownReparseGatingTests {

    private static let seed = "# Alpha\n\none two three.\n\n# Beta\n\nfour five six.\n"
    private static let edited = "# Alpha\n\nREPARSE edit.\n\n# Beta\n\nfour five six.\n"

    private struct Fixture {
        let db: ProjectDatabase
        let pid: String
        let editorState: EditorViewState
        /// nil in the fallback arm (no block-sync service at all, so `.noWriter`).
        let sync: BlockSyncService?
        let webView: WKWebView?
        /// The writer's next sequence before the run (writer arm only): the reserved-turn count is read against it.
        let sequenceBefore: UInt64?
    }

    /// `withWriter`: true installs a real block-sync service with a real writer on the editor state (the app's normal
    /// state: Milkdown's `onWebViewReady` configured it before the user ever reached Markdown); false leaves the editor
    /// state without one (the `.noWriter` fallback).
    private func makeFixture(withWriter: Bool) throws -> Fixture {
        let db = try TestFixtureFactory.createTemporary(content: Self.seed)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let editorState = EditorViewState()
        editorState.projectDatabase = db
        editorState.currentProjectId = pid
        editorState.editorMode = .source
        editorState.sourceReparseDebounce = .milliseconds(30)
        var sync: BlockSyncService?
        var webView: WKWebView?
        if withWriter {
            let view = WKWebView()
            let service = BlockSyncService()
            service.configure(database: db, projectId: pid, webView: view)
            service.editorState = editorState
            editorState.blockSyncService = service
            sync = service
            webView = view
        }
        return Fixture(
            db: db, pid: pid, editorState: editorState, sync: sync, webView: webView,
            sequenceBefore: sync?.testWriterHandle?.nextSequence)
    }

    private func paragraphTexts(_ fixture: Fixture) throws -> [String] {
        try TestFixtureFactory.fetchBlocks(from: fixture.db).filter { $0.blockType == .paragraph }.map(\.textContent)
    }

    private func arm(_ editorState: EditorViewState, sourceLocation: SourceLocation = #_sourceLocation) -> LifecycleToken? {
        guard case .armed(let token) = editorState.armLifecycle(.close, wasGettingStarted: false) else {
            Issue.record("could not arm a close token", sourceLocation: sourceLocation)
            return nil
        }
        return token
    }

    /// Zooms the fixture onto Alpha, as `zoomToSection` leaves it, with `edited` as the zoomed editor content.
    private func zoomOntoAlpha(_ fixture: Fixture) throws {
        let blocks = try TestFixtureFactory.fetchBlocks(from: fixture.db)
        let alpha = try #require(blocks.first { $0.blockType == .heading && $0.textContent == "Alpha" })
        let beta = try #require(blocks.first { $0.blockType == .heading && $0.textContent == "Beta" })
        fixture.editorState.zoomedSectionId = alpha.id
        fixture.editorState.zoomedSectionIds = [alpha.id]
        fixture.editorState.zoomedBlockRange = (start: alpha.sortOrder, end: beta.sortOrder)
    }

    /// Schedules the re-parse exactly as `handleContentChange` does. The full-document branch reads the project
    /// from `services.documentManager` at SCHEDULE time, and `DocumentManager` has only its process-wide
    /// singleton, so the singleton is pointed at this fixture for the one synchronous call and put back before
    /// anything can suspend (no other test can observe it).
    private func schedule(_ fixture: Fixture, content: String) {
        fixture.editorState.content = content
        let documentManager = DocumentManager.shared
        let priorDatabase = documentManager.projectDatabase
        let priorProjectId = documentManager.projectId
        documentManager.projectDatabase = fixture.db
        documentManager.projectId = fixture.pid
        defer {
            documentManager.projectDatabase = priorDatabase
            documentManager.projectId = priorProjectId
        }
        let services = ContentSyncServices(
            sectionSync: SectionSyncService(),
            annotationSync: AnnotationSyncService(),
            bibliographySync: BibliographySyncService(),
            footnoteSync: FootnoteSyncService(),
            autoBackup: AutoBackupService(),
            documentManager: documentManager,
            scanMemo: MarkdownScanMemo()
        )
        ContentSyncObserverHost<EmptyView>.scheduleSourceModeReparse(
            newValue: content, editorState: fixture.editorState, services: services)
    }

    /// Waits for the write the fire started (the per-block path returns from the fire's own Task as soon as the turn is
    /// reserved; the write is the writer's in-flight Task).
    private func settle(_ fixture: Fixture) async {
        while let pending = fixture.editorState.markdownWriter.inFlight {
            await pending.value
        }
    }

    /// The control's write: it happened, and it went the way the arm says (see the file header).
    private func expectWritten(
        _ fixture: Fixture, throughWriter: Bool, _ expectedText: String, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        await settle(fixture)
        #expect(try paragraphTexts(fixture).contains(expectedText), "control: the unarmed re-parse must write", sourceLocation: sourceLocation)
        let line = fixture.editorState.markdownWriter.lastTimingLine ?? "(no [MdWrite] line)"
        if throughWriter {
            #expect(line.contains("mode=rows") && line.contains("outcome=applied"),
                    "control: the write went THROUGH the writer; got: \(line)", sourceLocation: sourceLocation)
            #expect(fixture.sync?.testWriterHandle?.nextSequence == (fixture.sequenceBefore ?? 0) + 1,
                    "control: exactly one sequence was reserved", sourceLocation: sourceLocation)
        } else {
            #expect(line.contains("mode=legacy"), "control: no writer, so the legacy whole-document write ran; got: \(line)",
                    sourceLocation: sourceLocation)
        }
    }

    /// The "does not write" run: no text change, nothing reserved, no `[MdWrite]` line at all.
    private func expectNothingHappened(
        _ fixture: Fixture, before: [String], sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        #expect(try paragraphTexts(fixture) == before, "the re-parse must not write", sourceLocation: sourceLocation)
        #expect(fixture.editorState.markdownWriter.lastTimingLine == nil,
                "no [MdWrite] line: the write step never ran", sourceLocation: sourceLocation)
        if let sequenceBefore = fixture.sequenceBefore {
            #expect(fixture.sync?.testWriterHandle?.nextSequence == sequenceBefore, "nothing was reserved", sourceLocation: sourceLocation)
        }
    }

    // MARK: - Full-document branch

    @Test("""
        full re-parse, scheduled BEFORE arm, firing inside the window: does NOT write (control: the identical run, \
        unarmed, does, through the writer when there is one and through the legacy write when there is not)
        """, arguments: [true, false])
    func fullReparse_scheduledBeforeArm_firingDuringLifecycle_doesNotWrite(withWriter: Bool) async throws {
        // Control first: unarmed, the scheduled task writes.
        let control = try makeFixture(withWriter: withWriter)
        schedule(control, content: Self.edited)
        let controlTask = try #require(control.editorState.blockReparseTask, "precondition: a re-parse was scheduled")
        await controlTask.value
        try await expectWritten(control, throughWriter: withWriter, "REPARSE edit.")

        // Armed between schedule and fire.
        let fixture = try makeFixture(withWriter: withWriter)
        let before = try paragraphTexts(fixture)
        schedule(fixture, content: Self.edited)
        let task = try #require(fixture.editorState.blockReparseTask, "precondition: a re-parse was scheduled")
        _ = try #require(arm(fixture.editorState))
        await task.value
        await settle(fixture)

        try expectNothingHappened(fixture, before: before)
    }

    @Test("full re-parse: while a lifecycle is armed nothing is scheduled", arguments: [true, false])
    func fullReparse_whileArmed_isNotScheduled(withWriter: Bool) async throws {
        let fixture = try makeFixture(withWriter: withWriter)
        _ = try #require(arm(fixture.editorState))
        let generation = fixture.editorState.blockReparseGeneration

        schedule(fixture, content: Self.edited)

        #expect(fixture.editorState.blockReparseTask == nil, "no task may be scheduled while armed")
        #expect(fixture.editorState.blockReparseGeneration == generation, "and the generation must not move")
        #expect(fixture.editorState.markdownWriter.inFlight == nil)
    }

    @Test("""
        full re-parse: if the editor moved to another project before the task fired it does NOT write -- the db and \
        pid captured at schedule time are never used against a different project (the control is the first test: \
        the same task on the same project writes)
        """, arguments: [true, false])
    func fullReparse_projectChangedBeforeFire_doesNotWrite(withWriter: Bool) async throws {
        let fixture = try makeFixture(withWriter: withWriter)
        let before = try paragraphTexts(fixture)
        schedule(fixture, content: Self.edited)
        let task = try #require(fixture.editorState.blockReparseTask)
        fixture.editorState.currentProjectId = "another-project"
        await task.value
        await settle(fixture)

        try expectNothingHappened(fixture, before: before)
    }

    // MARK: - Zoomed branch (through the queue since Phase 5 job A8)

    @Test("""
        zoomed re-parse, scheduled BEFORE arm, firing inside the window: does NOT write (control: the identical \
        run, unarmed, does -- through the queue since Phase 5 job A8: exactly one sequence reserved)
        """)
    func zoomedReparse_scheduledBeforeArm_firingDuringLifecycle_doesNotWrite() async throws {
        let zoomedEdit = "# Alpha\n\nZOOMED re-parse edit.\n"

        let control = try makeFixture(withWriter: true)
        try zoomOntoAlpha(control)
        schedule(control, content: zoomedEdit)
        let controlTask = try #require(control.editorState.blockReparseTask, "precondition: a zoomed re-parse was scheduled")
        await controlTask.value
        await settle(control)
        #expect(try paragraphTexts(control).contains("ZOOMED re-parse edit."), "control: the unarmed zoomed re-parse must write")
        #expect(control.sync?.testWriterHandle?.nextSequence == (control.sequenceBefore ?? 0) + 1,
                "the zoomed write went through the queue (A8, MarkdownBlockWriter.writeZoomedNow): exactly one sequence reserved")
        #expect(control.editorState.markdownWriter.lastTimingLine == nil, "the zoomed branch has no [MdWrite] timing line")

        let fixture = try makeFixture(withWriter: true)
        try zoomOntoAlpha(fixture)
        let before = try paragraphTexts(fixture)
        schedule(fixture, content: zoomedEdit)
        let task = try #require(fixture.editorState.blockReparseTask, "precondition: a zoomed re-parse was scheduled")
        _ = try #require(arm(fixture.editorState))
        await task.value
        await settle(fixture)

        #expect(try paragraphTexts(fixture) == before, "a zoomed re-parse firing inside the window must not write")
        #expect(fixture.sync?.testWriterHandle?.nextSequence == fixture.sequenceBefore, "and reserves no turn on the queue")
    }

    @Test("zoomed re-parse: while a lifecycle is armed nothing is scheduled")
    func zoomedReparse_whileArmed_isNotScheduled() async throws {
        let fixture = try makeFixture(withWriter: true)
        try zoomOntoAlpha(fixture)
        _ = try #require(arm(fixture.editorState))
        let generation = fixture.editorState.blockReparseGeneration

        schedule(fixture, content: "# Alpha\n\nZOOMED re-parse edit.\n")

        #expect(fixture.editorState.blockReparseTask == nil)
        #expect(fixture.editorState.blockReparseGeneration == generation)
    }

    @Test("zoomed re-parse: if the editor moved to another project before the task fired it does NOT write")
    func zoomedReparse_projectChangedBeforeFire_doesNotWrite() async throws {
        let fixture = try makeFixture(withWriter: true)
        try zoomOntoAlpha(fixture)
        let before = try paragraphTexts(fixture)
        schedule(fixture, content: "# Alpha\n\nZOOMED re-parse edit.\n")
        let task = try #require(fixture.editorState.blockReparseTask)
        fixture.editorState.currentProjectId = "another-project"
        await task.value

        #expect(try paragraphTexts(fixture) == before)
    }
}
