//
//  MarkdownReparseGatingTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C4, P5 (slice-3a-1b-everyday.md section 5.3, coder obligation 24): the
//  debounced Source Mode re-parse (`ContentSyncObserverHost.scheduleSourceModeReparse`, both the full-document
//  and the zoomed branch) is a DIRECT whole-document write outside the writer, with `db`/`pid` read at schedule
//  time. While a close / project switch / quit holds the editor it must not write:
//
//    - while armed it is not SCHEDULED at all;
//    - one scheduled BEFORE the lifecycle armed and firing inside the window does NOT write (the lifecycle's own
//      whole-document save carries the same text, and a write landing after it is what the queue prevents);
//    - at fire time it also re-checks that the editor is still on the project it was scheduled for.
//
//  Every "does not write" test has a CONTROL: the identical run, unarmed, DOES write. Without it a test that
//  merely never reached the write would pass.
//
//  The debounce (one second in the app) is shortened per editor state (`sourceReparseDebounce`), and the tests
//  await the re-parse Task itself rather than sleeping.
//

import Foundation
import SwiftUI
import Testing
@testable import final_final

@Suite("Markdown re-parse gating (P5) — Tier 1 (t-94369a83 3a-1b C4)", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct MarkdownReparseGatingTests {

    private static let seed = "# Alpha\n\none two three.\n\n# Beta\n\nfour five six.\n"
    private static let edited = "# Alpha\n\nREPARSE edit.\n\n# Beta\n\nfour five six.\n"

    private struct Fixture {
        let db: ProjectDatabase
        let pid: String
        let editorState: EditorViewState
    }

    private func makeFixture() throws -> Fixture {
        let db = try TestFixtureFactory.createTemporary(content: Self.seed)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let editorState = EditorViewState()
        editorState.projectDatabase = db
        editorState.currentProjectId = pid
        editorState.editorMode = .source
        editorState.sourceReparseDebounce = .milliseconds(30)
        return Fixture(db: db, pid: pid, editorState: editorState)
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
            documentManager: documentManager
        )
        ContentSyncObserverHost<EmptyView>.scheduleSourceModeReparse(
            newValue: content, editorState: fixture.editorState, services: services)
    }

    // MARK: - Full-document branch

    @Test("""
        full re-parse, scheduled BEFORE arm, firing inside the window: does NOT write (control: the identical run, \
        unarmed, does)
        """)
    func fullReparse_scheduledBeforeArm_firingDuringLifecycle_doesNotWrite() async throws {
        // Control first: unarmed, the scheduled task writes.
        let control = try makeFixture()
        schedule(control, content: Self.edited)
        let controlTask = try #require(control.editorState.blockReparseTask, "precondition: a re-parse was scheduled")
        await controlTask.value
        #expect(try paragraphTexts(control).contains("REPARSE edit."), "control: the unarmed re-parse must write")

        // Armed between schedule and fire.
        let fixture = try makeFixture()
        let before = try paragraphTexts(fixture)
        schedule(fixture, content: Self.edited)
        let task = try #require(fixture.editorState.blockReparseTask, "precondition: a re-parse was scheduled")
        _ = try #require(arm(fixture.editorState))
        await task.value

        #expect(try paragraphTexts(fixture) == before, "a re-parse firing inside the window must not write")
    }

    @Test("full re-parse: while a lifecycle is armed nothing is scheduled")
    func fullReparse_whileArmed_isNotScheduled() async throws {
        let fixture = try makeFixture()
        _ = try #require(arm(fixture.editorState))
        let generation = fixture.editorState.blockReparseGeneration

        schedule(fixture, content: Self.edited)

        #expect(fixture.editorState.blockReparseTask == nil, "no task may be scheduled while armed")
        #expect(fixture.editorState.blockReparseGeneration == generation, "and the generation must not move")
    }

    @Test("""
        full re-parse: if the editor moved to another project before the task fired it does NOT write -- the db and \
        pid captured at schedule time are never used against a different project (the control is the first test: \
        the same task on the same project writes)
        """)
    func fullReparse_projectChangedBeforeFire_doesNotWrite() async throws {
        let fixture = try makeFixture()
        let before = try paragraphTexts(fixture)
        schedule(fixture, content: Self.edited)
        let task = try #require(fixture.editorState.blockReparseTask)
        fixture.editorState.currentProjectId = "another-project"
        await task.value

        #expect(try paragraphTexts(fixture) == before, "a re-parse scheduled for project A must not write once the editor is on B")
    }

    // MARK: - Zoomed branch

    @Test("""
        zoomed re-parse, scheduled BEFORE arm, firing inside the window: does NOT write (control: the identical \
        run, unarmed, does)
        """)
    func zoomedReparse_scheduledBeforeArm_firingDuringLifecycle_doesNotWrite() async throws {
        let zoomedEdit = "# Alpha\n\nZOOMED re-parse edit.\n"

        let control = try makeFixture()
        try zoomOntoAlpha(control)
        schedule(control, content: zoomedEdit)
        let controlTask = try #require(control.editorState.blockReparseTask, "precondition: a zoomed re-parse was scheduled")
        await controlTask.value
        #expect(try paragraphTexts(control).contains("ZOOMED re-parse edit."), "control: the unarmed zoomed re-parse must write")

        let fixture = try makeFixture()
        try zoomOntoAlpha(fixture)
        let before = try paragraphTexts(fixture)
        schedule(fixture, content: zoomedEdit)
        let task = try #require(fixture.editorState.blockReparseTask, "precondition: a zoomed re-parse was scheduled")
        _ = try #require(arm(fixture.editorState))
        await task.value

        #expect(try paragraphTexts(fixture) == before, "a zoomed re-parse firing inside the window must not write")
    }

    @Test("zoomed re-parse: while a lifecycle is armed nothing is scheduled")
    func zoomedReparse_whileArmed_isNotScheduled() async throws {
        let fixture = try makeFixture()
        try zoomOntoAlpha(fixture)
        _ = try #require(arm(fixture.editorState))
        let generation = fixture.editorState.blockReparseGeneration

        schedule(fixture, content: "# Alpha\n\nZOOMED re-parse edit.\n")

        #expect(fixture.editorState.blockReparseTask == nil)
        #expect(fixture.editorState.blockReparseGeneration == generation)
    }

    @Test("zoomed re-parse: if the editor moved to another project before the task fired it does NOT write")
    func zoomedReparse_projectChangedBeforeFire_doesNotWrite() async throws {
        let fixture = try makeFixture()
        try zoomOntoAlpha(fixture)
        let before = try paragraphTexts(fixture)
        schedule(fixture, content: "# Alpha\n\nZOOMED re-parse edit.\n")
        let task = try #require(fixture.editorState.blockReparseTask)
        fixture.editorState.currentProjectId = "another-project"
        await task.value

        #expect(try paragraphTexts(fixture) == before)
    }
}
