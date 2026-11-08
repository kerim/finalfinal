//
//  LifecycleTailHarness.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C5b: the shared harness for the REAL tails (`ContentView+LifecycleTails.swift`).
//  Where `LifecycleFlushHarness` drives the save sequence with recording tail doubles, this one wires a bare,
//  never-mounted `ContentView()` (the `ProjectCloseStaleContentTests` pattern: its `@State` services are plain
//  reference types, directly usable) to a temporary project database, a REAL `BlockSyncService` (JavaScript through
//  `testJSEvaluator`, no WebView load), real bibliography/footnote services on the same writer and a real
//  `AutoBackupService`, so a test can run `ContentView.runCloseTail` / `runOpenTail` / `runCreateTail` directly,
//  or the whole `LifecycleEntry.run` with the host `installLifecycleHost()` installs.
//
//  What it deliberately does NOT do: open a project in `DocumentManager.shared`. After a close, the tail must not
//  need it (N7), and the tests prove that by never providing it.
//
//  Item 32: tests using `withEntry` read `entryEvents` after the block (the harness copies them out just before
//  `LifecycleEntry` is reset), and assert the `.armed` event so a pass-through can never make a test pass vacuously.
//

import Foundation
import GRDB
import Testing
import WebKit
@testable import final_final

@MainActor
final class LifecycleTailRig {
    nonisolated static let seed = "# Alpha\n\none two three.\n\n# Beta\n\nfour five six.\n"
    nonisolated static let fresh = "# Alpha\n\nfresh Y paragraph.\n\n# Beta\n\nfour five six.\n"

    let db: ProjectDatabase
    let pid: String
    /// A `var` so a test can set `onProjectClosed` before the host is installed (the host closures capture a copy).
    var view: ContentView
    let toasts = ToastCenter()
    let js = ScriptedJSEvaluator()
    let writerEvents = WriterEventLog()
    /// What `window.FinalFinal.getContent()` answers.
    var fetchAnswer: String? = LifecycleTailRig.fresh
    /// The never-loaded stub view the editor "has mounted". Strong here; `FindBarState` holds it weakly.
    private(set) var webView: WKWebView?
    /// What `LifecycleEntry` recorded during the last `withEntry` block.
    private(set) var entryEvents: [LifecycleEntry.Event] = []

    var editorState: EditorViewState { view.editorState }
    var sync: BlockSyncService { view.blockSyncService }
    var backup: AutoBackupService { view.autoBackupService }
    var writer: DocumentWriter? { sync.testWriterHandle }

    /// - Parameter mountedEditor: when true the editor has a (stub) WebView, so the save sequence can fetch;
    ///   direct tail tests leave it off so no JavaScript is ever evaluated against a never-loaded view.
    init(content: String = LifecycleTailRig.seed, mountedEditor: Bool = false) throws {
        db = try TestFixtureFactory.createTemporary(content: content)
        pid = try TestFixtureFactory.getProjectId(from: db)
        view = ContentView()

        let editorState = view.editorState
        editorState.toastCenter = toasts
        editorState.projectDatabase = db
        editorState.currentProjectId = pid
        editorState.content = content

        // The wiring `ContentView.configureSyncServices` does, for the parts the sequence and the tails read.
        let sync = view.blockSyncService
        let stub = WKWebView()
        webView = stub
        sync.configure(database: db, projectId: pid, webView: stub)
        sync.editorState = editorState
        sync.testWriterEventHandler = { [writerEvents] event in writerEvents.append(event) }
        sync.testJSEvaluator = { [unowned self] script in
            if script.contains("holdReportsForSave") { return heldReadAnswer(content: self.fetchAnswer) }
            if script.contains("getContent()") { return self.fetchAnswer }
            return try await self.js.evaluate(script)
        }
        editorState.blockSyncService = sync

        let bibliography = view.bibliographySyncService
        bibliography.configure(database: db, projectId: pid)
        bibliography.systemWriter = SystemWriter(blockSync: sync)
        editorState.bibliographySyncService = bibliography
        let footnotes = view.footnoteSyncService
        footnotes.configure(database: db, projectId: pid)
        footnotes.systemWriter = SystemWriter(blockSync: sync)
        editorState.footnoteSyncService = footnotes

        let backup = view.autoBackupService
        backup.configure(database: db, projectId: pid)
        backup.toastCenter = toasts
        backup.editorState = editorState

        if mountedEditor { view.findBarState.activeWebView = stub }
        js.answer("flushPendingBlockChanges", true)
    }

    /// Whether the editor's reports were let flow again (`releaseReportHold`, which the abort routine sends without awaiting it):
    /// waits a bounded while (1 s) for the call. Replaces the poll-timer check (`testPollTimerIsArmed`) of before Phase 5 B4.
    func reportHoldReleased() async -> Bool {
        for _ in 0..<100 {
            if js.callCount("releaseReportHold") > 0 { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return js.callCount("releaseReportHold") > 0
    }

    /// Stops everything a test that did NOT run a tail started (timers), so nothing outlives the test. Safe after a
    /// tail has already reset the services.
    func shutdown() {
        backup.reset()
        view.bibliographySyncService.reset()
        view.footnoteSyncService.reset()
        editorState.lifecycleBarrier?.release()
        editorState.lifecycleBarrier = nil
    }

    // MARK: - Arming

    /// Arms a token of `kind` on the editor state, as `LifecycleEntry.run` does, for a test that calls a tail
    /// directly.
    func arm(_ kind: LifecycleKind, wasGettingStarted: Bool = false, sourceLocation: SourceLocation = #_sourceLocation) -> LifecycleToken {
        guard case .armed(let token) = editorState.armLifecycle(kind, wasGettingStarted: wasGettingStarted) else {
            Issue.record("the rig could not arm a \(kind) token", sourceLocation: sourceLocation)
            return LifecycleToken(kind: kind, wasGettingStarted: wasGettingStarted)
        }
        return token
    }

    /// Takes the writer barrier the way step 8 does: reached at once on an idle writer, recorded in
    /// `lifecycleBarrier` (N9). A test then has a HELD barrier to retire.
    @discardableResult
    func holdBarrier(sourceLocation: SourceLocation = #_sourceLocation) async -> BarrierHandle? {
        guard case .granted(let handle) = sync.requestLifecycleBarrier() else {
            Issue.record("the writer did not grant a barrier", sourceLocation: sourceLocation)
            return nil
        }
        editorState.lifecycleBarrier = handle
        let outcome = await handle.wait(timeout: 2)
        #expect(outcome == .reached, sourceLocation: sourceLocation)
        return handle
    }

    /// Starts a system write (`.headingLevels`) and lets it reserve and park above a held barrier. The task's value
    /// is what the write finally reported.
    func parkSystemWrite() async -> Task<SystemWriteResult<Int>, Never> {
        let identity = SystemWriteIdentity(projectId: pid, database: db)
        let sync = self.sync
        let task = Task { @MainActor in
            await sync.performSystemWrite(
                identity: identity, kind: .headingLevels, stillWanted: { true },
                body: { _ in SystemWriteBody(value: 1) })
        }
        var waited = 0
        while editorState.systemWriteInFlight == 0, waited < 400 {
            try? await Task.sleep(for: .milliseconds(5))
            waited += 1
        }
        // Reserved and (above a held barrier) parked: let it reach `waitForTurnAsync`.
        try? await Task.sleep(for: .milliseconds(50))
        return task
    }

    // MARK: - The entry

    /// Installs a `LifecycleEntry` environment that reads THIS rig, installs the REAL host on the editor state
    /// (`installLifecycleHost()`), then runs `body`. The entry's global state is reset before and after.
    /// - Parameter isGettingStartedProvider: when set, answers `DocumentManager.isGettingStartedProject` live (round
    ///   C8b), so a test can flip it inside `perform` the way opening another project does, and prove the tail reads
    ///   the token's `wasGettingStarted` (captured at arm, N1) and not this.
    func withEntry(
        bounds: LifecycleBounds = .production,
        isGettingStarted: Bool = false,
        isGettingStartedProvider: (@MainActor () -> Bool)? = nil,
        _ body: () async throws -> Void
    ) async rethrows {
        LifecycleEntry.environment = LifecycleEnvironment(
            hasOpenProject: { true },
            isGettingStartedProject: { isGettingStartedProvider?() ?? isGettingStarted },
            editorState: { [unowned self] in self.view.editorState },
            structuralUndoController: { [unowned self] in self.view.structuralUndoController },
            bounds: bounds
        )
        LifecycleEntry.resetForTests()
        view.installLifecycleHost()
        defer {
            entryEvents = LifecycleEntry.testEvents
            editorState.lifecycleHost = nil
            LifecycleEntry.environment = .production
            LifecycleEntry.resetForTests()
        }
        try await body()
    }

    // MARK: - Reading the database

    /// `previewMarkdown` of every snapshot row of the project (the automatic versions and any other).
    func snapshotPreviews() throws -> [String] {
        try db.dbWriter.read { database in
            try String.fetchAll(
                database,
                sql: "SELECT previewMarkdown FROM snapshot WHERE projectId = ? ORDER BY createdAt",
                arguments: [pid])
        }
    }

    func snapshotCount() throws -> Int {
        try db.dbWriter.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM snapshot WHERE projectId = ?", arguments: [pid]) ?? 0
        }
    }

    func paragraphTexts() throws -> [String] {
        try TestFixtureFactory.fetchBlocks(from: db).filter { $0.blockType == .paragraph }.map(\.textContent)
    }
}
