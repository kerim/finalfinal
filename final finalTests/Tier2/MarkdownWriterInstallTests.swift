//
//  MarkdownWriterInstallTests.swift
//  final finalTests
//
//  t-94369a83 Phase 4a, plan v2 section 3, tests U4, with judge verdict 2 note C2: Markdown and the block-sync writer.
//
//  WHAT THE REAL FLOWS ARE (judge C2 correction). `EditorViewState.editorMode` defaults to `.wysiwyg` and only the user's
//  switch changes it, so the app always OPENS in Rich Text, where Milkdown's `onWebViewReady` configures the block-sync
//  service and its writer. No production flow reaches Markdown without a writer:
//
//    - a project switch while in Markdown installs the NEW project's writer through `reconfigure` (the open tail), in
//      both modes;
//    - `BlockSyncService.ensureWriter`, called from CodeMirror's `onWebViewReady` through
//      `ContentView.prepareMarkdownBlockWriter`, is a GUARDED SAFETY NET for any path that gets there without one. It is
//      a no-op while a lifecycle holds the editor, while the editor state names another project (a switch between its
//      open and its tail), and when a live writer for this database and project exists.
//
//  So the safety net is tested DIRECTLY (a service with no writer), and the real flow is tested as it happens
//  (`reconfigure`, then the typing). `BlockSyncService.ensureWriter`'s own rules are in `MarkdownBlockWriteTests`; this file
//  covers the wiring entry (`prepareMarkdownBlockWriter`), the real flow, the bibliography-then-close sequence on the
//  queue, and the forced `.noWriter` fallback.
//

import Foundation
import SwiftUI
import Testing
@testable import final_final

@Suite("Markdown writer install and fallback — Tier 2 (t-94369a83 Phase 4a, U4)", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct MarkdownWriterInstallTests {

    private static let base = "# Alpha\n\nOne.\n\nTwo.\n\n# Beta\n\nFour."
    private static let typed = base.replacingOccurrences(of: "One.", with: "One, typed.")

    /// The wiring entry, with the `DocumentManager` singleton pointed at `database` for the one synchronous call.
    private func prepare(
        _ editorState: EditorViewState, _ sync: BlockSyncService, database: ProjectDatabase, projectId: String
    ) {
        let documentManager = DocumentManager.shared
        let priorDatabase = documentManager.projectDatabase
        let priorProjectId = documentManager.projectId
        documentManager.projectDatabase = database
        documentManager.projectId = projectId
        defer {
            documentManager.projectDatabase = priorDatabase
            documentManager.projectId = priorProjectId
        }
        ContentView.prepareMarkdownBlockWriter(editorState: editorState, documentManager: documentManager, blockSyncService: sync)
    }

    private struct Bare {
        let db: ProjectDatabase
        let pid: String
        let sync: BlockSyncService
        let editorState: EditorViewState
    }

    /// A project open in an editor state whose block-sync service has NEVER been configured: no writer.
    private func bare() throws -> Bare {
        let content = Self.base
        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let sync = BlockSyncService()
        let editorState = EditorViewState()
        editorState.blockSyncService = sync
        editorState.projectDatabase = db
        editorState.currentProjectId = pid
        editorState.editorMode = .source
        editorState.sourceContent = content
        return Bare(db: db, pid: pid, sync: sync, editorState: editorState)
    }

    // MARK: - The safety net, driven directly

    @Test("prepareMarkdownBlockWriter on a service with no writer installs one, records the load, and typing then goes through the writer")
    func installsAWriterWhereThereIsNone() async throws {
        let setup = try bare()
        #expect(setup.sync.testWriterHandle == nil, "precondition: no writer")

        prepare(setup.editorState, setup.sync, database: setup.db, projectId: setup.pid)

        let writer = try #require(setup.sync.testWriterHandle)
        #expect(writer.database === setup.db && writer.projectId == setup.pid)
        #expect(setup.editorState.markdownWriter.loadedText == Self.base, "the Markdown editor's load was recorded")
        #expect(setup.editorState.markdownWriter.baseline.isRows)

        let disposition = setup.editorState.markdownWriter.prepareAndStart(
            text: Self.typed, database: setup.db, projectId: setup.pid, service: setup.sync, refire: {})
        #expect(disposition == .started)
        while let pending = setup.editorState.markdownWriter.inFlight { await pending.value }
        let stored = BlockParser.assembleMarkdown(from: MarkdownBlockDiff.assemblyOrderedNonEmpty(try TestFixtureFactory.fetchBlocks(from: setup.db)))
        #expect(stored == Self.typed)
        #expect(setup.sync.testWriterLedger.markdownStaleEpochRejections == 0)
    }

    @Test("prepareMarkdownBlockWriter is a no-op for the writer while a lifecycle holds the editor, but still records the load")
    func noOpWhileALifecycleIsArmed() throws {
        let setup = try bare()
        guard case .armed(let token) = setup.editorState.armLifecycle(.close, wasGettingStarted: false) else {
            Issue.record("could not arm a close token")
            return
        }
        prepare(setup.editorState, setup.sync, database: setup.db, projectId: setup.pid)
        #expect(setup.sync.testWriterHandle == nil, "no writer is installed under a lifecycle token")
        #expect(setup.editorState.markdownWriter.loadedText == Self.base)
        setup.editorState.clearLifecycle(token.id)
    }

    @Test("prepareMarkdownBlockWriter is a no-op when the editor state still names another project (a switch between its open and its tail)")
    func noOpWhenTheProjectsDiffer() throws {
        let setup = try bare()
        setup.editorState.currentProjectId = "the-old-project"
        prepare(setup.editorState, setup.sync, database: setup.db, projectId: setup.pid)
        #expect(setup.sync.testWriterHandle == nil)
    }

    @Test("prepareMarkdownBlockWriter leaves a live writer for this project alone")
    func leavesALiveWriterAlone() throws {
        let rig = try MarkdownWriterRig(content: Self.base)
        let existing = try #require(rig.sync.testWriterHandle)
        rig.editorState.sourceContent = Self.base
        prepare(rig.editorState, rig.sync, database: rig.db, projectId: rig.pid)
        #expect(rig.sync.testWriterHandle === existing, "the same writer instance")
        #expect(rig.markdownWriter.loadedText == Self.base)
    }

    @Test("under the legacy UI-test flag the wiring entry does nothing at all: no writer, no recorded load")
    func inertUnderTheLegacyFlag() throws {
        let setup = try bare()
        setup.editorState.markdownWriter.isLegacyReparse = true
        prepare(setup.editorState, setup.sync, database: setup.db, projectId: setup.pid)
        #expect(setup.sync.testWriterHandle == nil)
        #expect(setup.editorState.markdownWriter.loadedText == nil)
    }

    // MARK: - The real flow: a project switch while in Markdown

    @Test("""
        the real flow: a project switch while in Markdown installs project B's writer through `reconfigure`; the safety net is \
        a no-op before the open tail (the editor state still names A) and after it (the writer exists), and B's typing goes through it
        """)
    func projectSwitchInstallsTheWriterThroughReconfigure() async throws {
        let rig = try MarkdownWriterRig(content: Self.base)
        let dbB = try TestFixtureFactory.createTemporary(content: "# Bravo\n\nB original.")
        let pidB = try TestFixtureFactory.getProjectId(from: dbB)
        let writerA = try #require(rig.sync.testWriterHandle)

        // The switch's open has swapped the document manager to B; the tail has not yet re-pointed the editor state.
        rig.editorState.sourceContent = Self.base
        prepare(rig.editorState, rig.sync, database: dbB, projectId: pidB)
        #expect(rig.sync.testWriterHandle === writerA, "before the tail: the project-mismatch rule makes the safety net a no-op")

        // The open tail: `reconfigure` installs B's writer, and the editor state follows.
        await rig.sync.reconfigure(database: dbB, projectId: pidB)
        rig.editorState.currentProjectId = pidB
        rig.editorState.projectDatabase = dbB
        rig.markdownWriter.reset()
        let writerB = try #require(rig.sync.testWriterHandle)
        #expect(writerB !== writerA && writerB.projectId == pidB && writerB.database === dbB)

        // CodeMirror becomes ready on B: the safety net finds the writer and leaves it.
        rig.editorState.sourceContent = "# Bravo\n\nB original."
        prepare(rig.editorState, rig.sync, database: dbB, projectId: pidB)
        #expect(rig.sync.testWriterHandle === writerB, "after the tail: the writer reconfigure installed is the one that stays")

        // B's typing is saved through B's writer, and A's database is untouched.
        let disposition = rig.markdownWriter.prepareAndStart(
            text: "# Bravo\n\nB typed.", database: dbB, projectId: pidB, service: rig.sync, refire: {})
        #expect(disposition == .started)
        await rig.settle()
        let bTexts = try TestFixtureFactory.fetchBlocks(from: dbB).filter { $0.blockType == .paragraph }.map(\.textContent)
        #expect(bTexts == ["B typed."])
        #expect(try rig.storedText() == Self.base, "project A was not touched")
    }

    // A bibliography update followed by a close, both on the queue, needs the process-wide Zotero singleton: it is in
    // `MarkdownBibliographyFlushTests+Lifecycle.swift`, with the other tests that own it.

    // MARK: - A forced `.noWriter` falls back to today's whole-document writes

    @Test("with no writer at all the debounced re-parse and the bibliography flush fall back to the whole-document write", arguments: [true, false])
    func noWriterFallsBackToTheLegacyPath(serviceExistsButIsUnconfigured: Bool) async throws {
        let rig = try MarkdownWriterRig(content: Self.base)
        // The editor state holds its block-sync service WEAKLY: keep the unconfigured one alive here.
        let unconfigured: BlockSyncService? = serviceExistsButIsUnconfigured ? BlockSyncService() : nil
        rig.editorState.blockSyncService = unconfigured
        defer { withExtendedLifetime(unconfigured) {} }
        rig.editorState.content = Self.typed

        // The debounced re-parse's step (every gate has passed).
        ContentSyncObserverHost<EmptyView>.runMarkdownReparseFire(
            newValue: Self.typed, db: rig.db, pid: rig.pid, editorState: rig.editorState, services: rig.services)
        #expect(try rig.storedText() == Self.typed, "today's whole-document write ran, synchronously")
        #expect(rig.markdownWriter.lastTimingLine?.contains("mode=legacy") == true)
        #expect(rig.markdownWriter.inFlight == nil)
        #expect(rig.markdownWriter.baseline.isRows, "the whole-document write replaced the rows, so the baseline is the rows again")

        // The bibliography flush hook.
        let newer = Self.typed.replacingOccurrences(of: "Two.", with: "Two, newer.")
        rig.editorState.content = newer
        let hook = ContentView.makeBibliographyFlushHandler(for: rig.editorState)
        await hook(rig.pid, nil)
        #expect(try rig.storedText() == newer, "the hook wrote the whole document the old way")
    }
}
