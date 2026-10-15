//
//  MarkdownWriterRig.swift
//  final finalTests
//
//  t-94369a83 Phase 4a, coder C2: the shared rig for the unit tests of the per-block Markdown save
//  (`MarkdownBlockWriter`, `BlockSyncService+Markdown`). One temporary project database, a REAL `BlockSyncService`
//  with a REAL `DocumentWriter` (configured the way Milkdown's `onWebViewReady` configures it, on a never-loaded stub
//  WebView), and an `EditorViewState` in Markdown mode that points at both, loaded the way the app loads it: the
//  editor text came from the stored rows, so the writer's baseline is `.rows` (the everyday first-fire path).
//
//  What the rig gives a test:
//
//    - `fire(_:)`            the debounce fire's synchronous step (`MarkdownBlockWriter.prepareAndStart`), with the
//                            editor text set the way a keystroke sets it. Returns the writer's disposition.
//    - `settle()`            waits for the write in flight (the same `while let` wait the real fire does).
//    - `schedule(_:)`        the REAL debounced scheduler (`ContentSyncObserverHost.scheduleSourceModeReparse`), pointed
//                            at this project for the one synchronous call (it reads the project from the
//                            `DocumentManager` singleton at SCHEDULE time, as `MarkdownReparseGatingTests` does).
//    - `hold()` / `release(_:)`  a held SYSTEM sequence: the Markdown write reserved after it waits its turn
//                            (`DocumentWriterSystemWriteTests`' technique: there is no separate release call, the held
//                            ticket is applied).
//    - `rows()` / `storedText()`  what the database holds, in assembly order.
//
//  Nothing here sleeps: tests wait on the writer's events (`WriterEventSignal`) or on the in-flight Task.
//

import Foundation
import GRDB
import SwiftUI
import Testing
import WebKit
@testable import final_final

@MainActor
final class MarkdownWriterRig {
    let db: ProjectDatabase
    let pid: String
    let sync: BlockSyncService
    let editorState: EditorViewState
    let services: ContentSyncServices
    /// Every `WriterEvent` the writer emitted (`.parked`, `.systemApplied`, `.refused`, ...).
    let events = WriterEventRecorder()
    /// How many times the writer asked for a normal debounce fire (`refire`) after a non-clean outcome.
    private(set) var refireCount = 0
    private let webView: WKWebView

    var markdownWriter: MarkdownBlockWriter { editorState.markdownWriter }
    /// Qualified: `import SwiftUI` makes the bare name ambiguous.
    var writer: final_final.DocumentWriter { sync.testWriterHandle! }   // swiftlint:disable:this force_unwrapping
    var ledger: LossLedger { sync.testWriterLedger }

    init(content: String, debounce: Duration = .milliseconds(20)) throws {
        db = try TestFixtureFactory.createTemporary(content: content)
        pid = try TestFixtureFactory.getProjectId(from: db)
        webView = WKWebView()
        sync = BlockSyncService()
        sync.configure(database: db, projectId: pid, webView: webView)
        editorState = EditorViewState()
        sync.editorState = editorState
        editorState.blockSyncService = sync
        editorState.projectDatabase = db
        editorState.currentProjectId = pid
        editorState.editorMode = .source
        editorState.sourceReparseDebounce = debounce
        services = ContentSyncServices(
            sectionSync: SectionSyncService(),
            annotationSync: AnnotationSyncService(),
            bibliographySync: BibliographySyncService(),
            footnoteSync: FootnoteSyncService(),
            autoBackup: AutoBackupService(),
            documentManager: DocumentManager.shared
        )
        let events = events
        sync.testWriterEventHandler = { events.append($0) }
        // The editor was just loaded from the stored rows: the writer's everyday starting point.
        editorState.content = content
        markdownWriter.noteLoaded(text: content, pid: pid)
    }

    // MARK: - Reading the database

    /// A real parse, isolated from the process-wide `ExportSettings` (both bibliography names given explicitly).
    func parse(_ markdown: String) -> [Block] {
        BlockParser.parse(markdown: markdown, projectId: pid, bibliographyHeaderName: "Bibliography", graceNames: [])
    }

    /// The stored rows in assembly order (empty fragments dropped), the order the editor text is assembled in.
    func rows() throws -> [Block] {
        MarkdownBlockDiff.assemblyOrderedNonEmpty(try TestFixtureFactory.fetchBlocks(from: db))
    }

    func storedText() throws -> String { BlockParser.assembleMarkdown(from: try rows()) }

    /// `[id: [lastWriteEpoch, lastWriteSequence]]` for every row.
    func stamps() throws -> [String: [Int64]] {
        try db.read { database in
            var result: [String: [Int64]] = [:]
            for row in try Row.fetchAll(database, sql: "SELECT id, lastWriteEpoch, lastWriteSequence FROM block") {
                result[row["id"] as String] = [row["lastWriteEpoch"] as Int64, row["lastWriteSequence"] as Int64]
            }
            return result
        }
    }

    /// Rows with the same fragment more than once (the signature of a duplicated insert).
    func duplicateFragments() throws -> [String] {
        let fragments = try rows().map(\.markdownFragment)
        return Dictionary(grouping: fragments, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
    }

    // MARK: - Firing

    /// The debounce fire's synchronous step, with the editor text set as a keystroke sets it. Does NOT wait for the
    /// write: use `settle()` (or `fireAndSettle`) for that.
    @discardableResult
    func fire(_ text: String) -> MarkdownBlockWriter.Disposition {
        editorState.content = text
        return markdownWriter.prepareAndStart(
            text: text, database: db, projectId: pid, service: sync, refire: { [weak self] in self?.refireCount += 1 })
    }

    @discardableResult
    func fireAndSettle(_ text: String) async -> MarkdownBlockWriter.Disposition {
        let disposition = fire(text)
        await settle()
        return disposition
    }

    /// Waits for the write in flight, the same `while let` loop the real fire and `writeNow` use.
    func settle() async {
        while let pending = markdownWriter.inFlight {
            await pending.value
        }
    }

    /// `writeNow` with the production guard set (`ContentView.bibliographyFlushGuardsHold`).
    func writeNow(overrideContent: String? = nil) async -> MarkdownBlockWriter.WriteNowOutcome {
        let pid = pid
        let editorState = editorState
        return await markdownWriter.writeNow(
            overrideContent: overrideContent,
            editorState: editorState,
            guardsHold: { ContentView.bibliographyFlushGuardsHold(editorState, scheduledForProjectId: pid) },
            refire: { [weak self] in self?.refireCount += 1 })
    }

    /// The REAL debounced scheduler. Returns the fire's Task (`editorState.blockReparseTask`) or nil when the
    /// scheduler declined (a lifecycle is armed, ...).
    @discardableResult
    func schedule(_ text: String) -> Task<Void, Never>? {
        editorState.content = text
        // The full-document branch reads the project from the `DocumentManager` singleton at SCHEDULE time: point it at
        // this rig for the one synchronous call and put it back before anything can suspend.
        let documentManager = DocumentManager.shared
        let priorDatabase = documentManager.projectDatabase
        let priorProjectId = documentManager.projectId
        documentManager.projectDatabase = db
        documentManager.projectId = pid
        defer {
            documentManager.projectDatabase = priorDatabase
            documentManager.projectId = priorProjectId
        }
        ContentSyncObserverHost<EmptyView>.scheduleSourceModeReparse(
            newValue: text, editorState: editorState, services: services)
        return editorState.blockReparseTask
    }

    // MARK: - Holding the queue

    /// Reserves a system sequence and leaves it open: every editor sequence reserved after it waits its turn.
    func hold() -> SystemTicket { writer.reserveSystem() }

    /// Applies the held system sequence (as `DocumentWriterSystemWriteTests` does), which lets the queue move on.
    func release(_ held: SystemTicket) async {
        let identity = SystemWriteIdentity(projectId: pid, database: db)
        let outcome = await writer.applySystemWrite(held.seq, kind: .headingLevels, identity: identity) { _ in
            SystemWriteBody(value: 1)
        }
        guard case .applied = outcome else {
            Issue.record("expected the held system write to apply, got \(outcome)")
            return
        }
    }

    /// A signal that fires the first time the writer parks a sequence on its turn (`.parked`).
    func parkedSignal() -> WriterEventSignal {
        let signal = WriterEventSignal(matching: { if case .parked = $0 { return true }; return false })
        let events = events
        sync.testWriterEventHandler = { event in
            events.append(event)
            signal.note(event)
        }
        return signal
    }

    // MARK: - Setting heading metadata

    /// Gives the heading whose text is `title` a status, tags and a word goal, so a test can see them survive.
    func setMetadata(onHeading title: String, status: SectionStatus, tags: [String], wordGoal: Int) throws {
        try db.write { database in
            guard var heading = try Block.filter(Block.Columns.projectId == pid)
                .filter(Block.Columns.blockType == BlockType.heading.rawValue)
                .filter(Block.Columns.textContent == title).fetchOne(database) else { return }
            heading.status = status
            heading.tags = tags
            heading.wordGoal = wordGoal
            try heading.update(database)
        }
    }

    func heading(_ title: String) throws -> Block? {
        try rows().first { $0.blockType == .heading && $0.textContent == title }
    }
}
