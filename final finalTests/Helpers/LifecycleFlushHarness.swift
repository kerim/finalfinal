//
//  LifecycleFlushHarness.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C3a: the shared harness for driving `EditorViewState.runLifecycleFlush`
//  (the first half of the lifecycle save sequence, slice-3a-1b-everyday.md section 4.2 steps 0-6) directly.
//  Later rounds' tests (C3b onward) reuse it.
//
//  What it wires: a temporary project database, a REAL `BlockSyncService` whose JavaScript goes through
//  `testJSEvaluator` (the BlockSyncPollWatchdogTests pattern: no run loop, no WebView load), a stub
//  `WKWebView` that is never loaded, an `EditorViewState` pointing at both, and a `StructuralUndoController`
//  the sequence reads for its section-operation guard. Every observable step appends a short tag to `log`,
//  in order, so a test can assert event ORDER ("the rebuild push landed before F").
//
//  Round C5a additions: the host records every `repostDeferredRebuilds` / `scheduleSourceModeReparse` call (and
//  whether a token was still armed when it was made), `reparseHandler` lets a test install the REAL scheduler
//  behind the recording closure, and `recordPushes()` replaces `pushBlockIds`'s JavaScript call with a recorder
//  (ids, whether the poll timer was armed, `isResettingContent`) that a test can park to stand in for a wedge.
//
//  Round C3b additions: `run` now plays `LifecycleEntry.execute`'s part after the sequence, releasing the
//  writer barrier the sequence leaves held (and recording what was held at return), `attachFootnoteService` /
//  `attachBibliographyService` wire real sync services onto the same writer, and `installEntry` points the
//  `LifecycleEntry` environment at this rig so entry-level tests (the cancelled outcome, `perform` after the
//  sequence) drive the same stack.
//

import Foundation
import Testing
import WebKit
@testable import final_final

/// Records every `WriterEvent` the writer emits. The handler is `@Sendable` and not guaranteed to fire on
/// the main actor, hence the lock.
final class WriterEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [WriterEvent] = []

    func append(_ event: WriterEvent) {
        lock.withLock { storage.append(event) }
    }

    var events: [WriterEvent] { lock.withLock { storage } }
}

@MainActor
final class LifecycleFlushHarness {
    nonisolated static let seed = "# Alpha\n\none two three.\n\n# Beta\n\nfour five six.\n"

    let db: ProjectDatabase
    let pid: String
    let sync: BlockSyncService
    let editorState: EditorViewState
    let js = ScriptedJSEvaluator()
    let controller = StructuralUndoController()
    let writerEvents = WriterEventLog()

    /// The harness's strong reference to the view the `BlockSyncService` was configured with. The service
    /// keeps its own view only WEAKLY; a test drops this (set to nil) to make the service's own view vanish.
    var webView: WKWebView?
    /// The view the host's `activeWebView` hands to the sequence. The same instance as `webView` until a
    /// test swaps it, which is how U8 makes the service's own view differ from the captured one.
    var hostView: WKWebView?
    /// What `window.FinalFinal.getContent()` answers. nil = the JS call returns nothing (a failed fetch).
    var fetchAnswer: String?
    /// When true, the host's `activeWebView` closure drops the harness's own reference to `hostView` right
    /// as it hands the view to the sequence, so only the sequence's capture keeps it alive.
    var dropOwnViewReferenceOnCapture = false
    /// Whether the captured (host) view was still alive at the first `getContent` call.
    private(set) var viewAliveAtFetch: Bool?
    private weak var hostViewProbe: WKWebView?
    private(set) var log: [String] = []

    /// Real sync services wired onto the same writer, kept strongly here (the editor state holds them weakly).
    private(set) var footnoteService: FootnoteSyncService?
    private(set) var bibliographyService: BibliographySyncService?
    /// The deadline of the last `run`, so a test can read how much budget the sequence left.
    private(set) var lastDeadline: LifecycleDeadline?
    /// What the sequence left held when it returned (before the harness released it, as `execute`'s defer does):
    /// the handle's sequence in `editorState.lifecycleBarrier`, and the writer's own open barrier.
    private(set) var barrierSeqHeldAtReturn: UInt64?
    /// What `LifecycleEntry` recorded during the last `withEntry` block (`LifecycleEntry.testEvents`, copied out
    /// just before the harness resets the entry's global state on the way out).
    private(set) var entryEvents: [LifecycleEntry.Event] = []
    private(set) var writerBarrierSeqAtReturn: UInt64?

    // MARK: Round C5a recorders

    /// One `pushBlockIds` call as the abort routine made it.
    struct PushRecord {
        let ids: [String]
        /// Whether the editor's reports had already been let flow again (`releaseReportHold`) at the moment of the push: the
        /// abort must push BEFORE it does (N14, item 13; it was the poll's restart until Phase 5 B4).
        let reportHoldReleased: Bool
        let isResettingContent: Bool
    }

    /// One `scheduleSourceModeReparse` call the host received.
    struct ReparseRequest {
        let content: String
        /// Whether a lifecycle token was still armed when the host was asked. P5's schedule-time gate drops a
        /// reparse scheduled while armed, so the abort must clear the token first.
        let lifecycleStillArmed: Bool
    }

    private(set) var pushes: [PushRecord] = []
    private(set) var reparseRequests: [ReparseRequest] = []
    /// For each `repostDeferredRebuilds` call: whether a lifecycle token was still armed.
    private(set) var repostCalls: [Bool] = []
    /// What the host does with a reparse request, after recording it (default: nothing). A test installs the real
    /// `ContentSyncObserverHost.scheduleSourceModeReparse` here.
    var reparseHandler: ((String) -> Void)?
    /// When set, a recorded push parks on it until the test opens it: the stand-in for an `evaluateJavaScript`
    /// that never returns.
    var pushGate: LifecycleEntryHarness.Gate?

    /// True when the service's own (weak) view reference is nil. Set up by `clearServiceOwnView()`, never by
    /// waiting for ARC.
    var serviceOwnViewIsNil: Bool { sync.testOwnWebViewIsNil }

    init(content: String = LifecycleFlushHarness.seed) throws {
        db = try TestFixtureFactory.createTemporary(content: content)
        pid = try TestFixtureFactory.getProjectId(from: db)
        let view = Self.makeView()
        webView = view
        hostView = view
        hostViewProbe = view
        sync = BlockSyncService()
        sync.configure(database: db, projectId: pid, webView: view)
        editorState = EditorViewState()
        sync.editorState = editorState
        editorState.blockSyncService = sync
        editorState.projectDatabase = db
        editorState.currentProjectId = pid
        editorState.content = content
        wire()
    }

    private func wire() {
        sync.testJSEvaluator = { [unowned self] script in
            if script.contains("holdReportsForSave") {
                // The Rich Text save's live read (Phase 5 B3): the content, wrapped with the report hold.
                self.noteFetch()
                return heldReadAnswer(content: self.fetchAnswer)
            }
            if script.contains("getContent()") {
                self.noteFetch()
                return self.fetchAnswer
            }
            self.note("poll")
            return try await self.js.evaluate(script)
        }
        sync.testWriterEventHandler = { [writerEvents] event in writerEvents.append(event) }
    }

    func note(_ tag: String) { log.append(tag) }

    private func noteFetch() {
        log.append("fetch")
        if viewAliveAtFetch == nil { viewAliveAtFetch = hostViewProbe != nil }
    }

    /// A never-loaded stub WebView, made in its own function so no local reference lingers in the caller.
    static func makeView() -> WKWebView {
        WKWebView()
    }

    /// Makes the service forget its own WebView by construction (a DEBUG seam on `BlockSyncService`), so a
    /// test never depends on when ARC releases a `WKWebView`.
    func clearServiceOwnView() {
        sync.testClearOwnWebView()
    }

    /// Replaces the view the host hands out with a different one (the service keeps its own).
    func swapHostView(to view: WKWebView) {
        hostView = view
        hostViewProbe = view
    }

    /// The host the sequence is handed. Only `activeWebView` does anything; the rest are inert.
    var host: LifecycleHost {
        LifecycleHost(
            activeWebView: { [unowned self] in
                self.note("activeWebView")
                let view = self.hostView
                if self.dropOwnViewReferenceOnCapture { self.hostView = nil }
                return view
            },
            runOpenTail: { [unowned self] _ in self.note("tail:open") },
            runCreateTail: { [unowned self] _, _ in self.note("tail:create") },
            runCloseTail: { [unowned self] _, _ in self.note("tail:close") },
            repostDeferredRebuilds: { [unowned self] in
                self.note("repost")
                self.repostCalls.append(self.editorState.activeLifecycle != nil)
            },
            scheduleSourceModeReparse: { [unowned self] content in
                self.note("reparse")
                self.reparseRequests.append(
                    ReparseRequest(content: content, lifecycleStillArmed: self.editorState.activeLifecycle != nil))
                self.reparseHandler?(content)
            },
            toastCenter: { ToastCenter() }
        )
    }

    /// Replaces `pushBlockIds`'s JavaScript call with a recorder (round C5a). Call before the run under test.
    func recordPushes() {
        sync.testPushBlockIdsHook = { [unowned self] ids in
            self.note("pushBlockIds")
            self.pushes.append(PushRecord(
                ids: ids,
                reportHoldReleased: self.js.callCount("releaseReportHold") > 0,
                isResettingContent: self.editorState.isResettingContent))
            await self.pushGate?.wait()
        }
    }

    /// Arms a token of `kind`, runs the sequence against it and clears the token, as `LifecycleEntry.run`
    /// does: the writer barrier the sequence leaves held is recorded and then released (`execute`'s defer,
    /// N9). `bounds` defaults to the production numbers; the guard and race tests pass a `scaled(_:)` copy so
    /// a real-clock wait stays short.
    func run(
        _ kind: LifecycleKind = .close,
        bounds: LifecycleBounds = .production,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> LifecycleFlushResult {
        guard case .armed(let token) = editorState.armLifecycle(kind, wasGettingStarted: false) else {
            Issue.record("the harness could not arm a \(kind) token", sourceLocation: sourceLocation)
            return LifecycleFlushResult()
        }
        let deadline = LifecycleDeadline(total: kind == .quit ? bounds.quitTotal : bounds.closeTotal)
        lastDeadline = deadline
        let result = await editorState.runLifecycleFlush(
            token: token,
            host: host,
            structuralUndoController: controller,
            deadline: deadline,
            bounds: bounds
        )
        barrierSeqHeldAtReturn = editorState.lifecycleBarrier?.seq
        writerBarrierSeqAtReturn = sync.testWriterHandle?.testOpenBarrierSeq
        editorState.lifecycleBarrier?.release()
        editorState.lifecycleBarrier = nil
        editorState.clearLifecycle(token.id)
        return result
    }

    // MARK: - Sync services (round C3b)

    /// A `FootnoteSyncService` on this rig's database and writer, attached to the editor state.
    @discardableResult
    func attachFootnoteService() -> FootnoteSyncService {
        let service = FootnoteSyncService()
        service.configure(database: db, projectId: pid)
        service.systemWriter = SystemWriter(blockSync: sync)
        editorState.footnoteSyncService = service
        footnoteService = service
        return service
    }

    /// A `BibliographySyncService` on this rig's database and writer, attached to the editor state.
    @discardableResult
    func attachBibliographyService() -> BibliographySyncService {
        let service = BibliographySyncService()
        service.configure(database: db, projectId: pid)
        service.systemWriter = SystemWriter(blockSync: sync)
        editorState.bibliographySyncService = service
        bibliographyService = service
        return service
    }

    /// Toggles SQLite's `query_only` pragma on the writer connection: with it ON any write throws, which a
    /// system write reports as `.failed` (the `SystemWriteOrderingTests` technique for forcing a real failure).
    func setQueryOnly(_ enabled: Bool) throws {
        try db.dbWriter.writeWithoutTransaction { database in
            try database.execute(sql: "PRAGMA query_only = \(enabled ? "ON" : "OFF")")
        }
    }

    // MARK: - The entry (round C3b)

    /// Installs a `LifecycleEntry` environment that reads THIS rig (an open project, this editor state, this
    /// controller, `bounds`) and mounts the rig's host on the editor state, then runs `body`. The entry's
    /// global state is reset before and after.
    func withEntry(
        bounds: LifecycleBounds = .production,
        isGettingStarted: Bool = false,
        _ body: () async throws -> Void
    ) async rethrows {
        LifecycleEntry.environment = LifecycleEnvironment(
            hasOpenProject: { true },
            isGettingStartedProject: { isGettingStarted },
            editorState: { [unowned self] in self.editorState },
            structuralUndoController: { [unowned self] in self.controller },
            bounds: bounds
        )
        LifecycleEntry.resetForTests()
        editorState.lifecycleHost = host
        defer {
            // Hand the recorded events out BEFORE the reset clears them: a test reads `entryEvents` after the
            // block, and `LifecycleEntry.testEvents` itself is empty by then.
            entryEvents = LifecycleEntry.testEvents
            editorState.lifecycleHost = nil
            LifecycleEntry.environment = .production
            LifecycleEntry.resetForTests()
        }
        try await body()
    }

    // MARK: - Reading the database

    func paragraphTexts() throws -> [String] {
        try TestFixtureFactory.fetchBlocks(from: db).filter { $0.blockType == .paragraph }.map(\.textContent)
    }

    func blocks() throws -> [Block] {
        try TestFixtureFactory.fetchBlocks(from: db)
    }

    /// The footnote definitions in the Notes rows, `label -> text`.
    func notesDefinitions() throws -> [String: String] {
        var result: [String: String] = [:]
        for block in try blocks() where block.isNotes && block.blockType == .paragraph {
            guard let parsed = FootnoteSyncService.parseNotesLabel(from: block.markdownFragment) else { continue }
            result[parsed.label] = parsed.text
        }
        return result
    }

    /// The footnote reference labels in the body (non-Notes) paragraphs, in order, as the Notes scanner sees them.
    func bodyFootnoteRefs() throws -> [String] {
        let body = try blocks().filter { !$0.isNotes && !$0.isBibliography }
        return FootnoteSyncService.extractFootnoteRefs(from: body.map(\.markdownFragment).joined(separator: "\n\n"))
    }

    /// Releases a wedged JS call and lets whatever was parked in it unwind (bounded, 100 ms), so nothing is still running against
    /// the temporary database when the test ends.
    func releaseWedgeAndSettle() async throws {
        js.releaseWedge()
        try await Task.sleep(for: .milliseconds(100))
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
}
