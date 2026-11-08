//
//  EditorFirstDeleteTests.swift
//  final finalTests
//
//  Tier 2 (t-94369a83 Phase 4b slice 2a, plan D1 and tests U5, U6, U14, U16): the controller's editor-first Delete Section, driven
//  with a REAL `BlockSyncService` and `DocumentWriter` whose JavaScript goes through `testJSEvaluator` (the pattern the poll
//  watchdog and lifecycle tests use: no run loop, no web page). The editor's side of a delete (the removal and its reply) is
//  scripted; what these tests pin is what Swift does with the reply: the order of its steps, that a batch is ALWAYS applied, and
//  that the database follows through the queued job.
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import GRDB
import Testing
import WebKit
@testable import final_final

/// The JSON `deleteSectionEditorFirst` answers: `batch` is what the call consumed, `removedLeaderIds` the leaders it took out and
/// `removedIds` every block it removed (nil: an editor that sends none, so the job makes no comparison).
struct EditorFirstReply: Encodable {
    var batch = BlockChanges()
    var succeeded = true
    var reason: String?
    var removedLeaderIds: [String] = []
    var removedIds: [String]?

    private enum CodingKeys: String, CodingKey {
        case batch
        case succeeded = "ok"
        case reason
        case removedLeaderIds
        case removedIds
    }
}

/// A temporary project, a `StructuralUndoController` wired to it, and a scripted editor.
///
/// Slice 2b (quick undo of a section delete): the scripted editor also answers the quick path's calls the way the real one does
/// (`undoSectionDeleteEditorFirst`, `redoSectionDeleteEditorFirst`, `resumeSyncAfterQuickUndo`, `getContent()`), WITHOUT naming any
/// production symbol the base commit lacks, so this file compiles with the production change taken out (the must-fail proof).
/// What it models, and how `contentChanged` is produced: see EditorFirstRig+QuickUndo.swift.
@MainActor
final class EditorFirstRig {
    let db: ProjectDatabase
    let pid: String
    /// This rig's share of the process's `DebugLog.always` lines (round 2d-i, addendum must-fix 2): only the lines that carry its project
    /// id, collected through a PRIVATE observer of the log, so a suite running in parallel (which writes `[EF-STRUCT] ... fell back` lines
    /// on purpose, and which may replace `DebugLog.alwaysSink` at any moment) can neither put a line in nor take one out.
    let logScope: RigLogScope
    let sync = BlockSyncService()
    let editorState = EditorViewState()
    let controller = StructuralUndoController()
    let unifiedUndo = UnifiedUndoService()
    let toasts = ToastCenter()
    let js = ScriptedJSEvaluator()
    /// The view the service is configured with (it keeps its own reference weakly).
    let view = WKWebView()
    /// Everything `deleteSectionEditorFirst` was asked, as the scripts the controller sent.
    var deleteScripts: [String] = []
    /// What the next `deleteSectionEditorFirst` call answers when no reply is registered for its root. Set by the test before it
    /// presses Delete Section.
    var deleteReply: Data?
    /// Replies by the root block id the call names (for tests that press Delete Section on several sections back to back).
    var repliesByRoot: [String: Data] = [:]
    /// The order spy's log.
    let spyLog = GateOrderLog()
    /// Everything the editor was asked, in order: `js <script>` for every call the controller made through its eval seams, and
    /// `setContent preserve=<flag>` for every `setContentWithBlockIds` push. One log, so a test can assert the order across both.
    let events = GateOrderLog()
    /// Every `setContentWithBlockIds` push the controller made (the push itself is replaced by `testSetContentHook`).
    var pushes: [Push] = []
    /// Alerts the controller asked to show.
    private(set) var alerts: [SectionOperationAlert] = []
    /// What `window.FinalFinal.getContent()` answers (the lifecycle's fetch and the old path's flush). nil = a failed fetch.
    var fetchAnswerProvider: (() -> String?)?
    /// What the old sequence's `window.FinalFinal.beginStructuralOp(...)` answers. `false` is an editor that does not exist yet.
    var beginStructuralOpAnswer = true
    /// What `window.FinalFinal.heldUndoPressCount()` answers: how many Cmd-Z / Cmd-Shift-Z presses the editor holds in its own queue
    /// when a close, quit or switch asks (fix round 5, part B). 0 unless a test says otherwise.
    var heldPressCountAnswer = 0
    /// How long the stub waits before it answers (fix round 8, F4).
    var heldPressCountDelay: Duration = .zero
    /// How many times the lifecycle asked the editor for that count (the asking itself is what a test of "only when the gate is
    /// busy" pins).
    var heldCountReads = 0
    /// What the editor's document becomes when the undo's checkpoint swap (`window.FinalFinal.performStructuralSwap(opId, 'undo')`)
    /// runs: the real swap replaces the editor's document with the checkpoint the delete captured, i.e. the document as it was before
    /// the delete, so the restored section is in the editor's own blocks again. nil leaves `editorText` alone. Without it a test that
    /// models the editor with `editorText` would hand the undo's merge-guarded re-push an editor that never got the section back.
    var editorTextAfterUndoSwap: String?
    /// The two sync services the controller was configured with (the footnote one is what a test holds in flight or reads).
    let bibliography = BibliographySyncService()
    let footnotes = FootnoteSyncService()
    /// A stand-in for the text the Rich Text editor holds: a test sets it to what the editor shows, and every merge-guarded push
    /// of the database's regions (`setContentWithBlockIds(preserveUserBlocks: true)`, the one the rebuilds and the undo's settle
    /// use) replaces it with the pushed text, as the real editor's document is replaced. nil until a test sets it; a test's
    /// `fetchAnswerProvider` can answer it for the lifecycle's fetch.
    var editorText: String?

    // MARK: Quick undo and redo (slice 2b)

    /// The clicks by operation id.
    var clicks: [String: DeleteClick] = [:]
    var quickUndoAnswer: QuickUndoAnswer = .restore
    /// Awaited inside the quick undo's answer, before it is returned: holds the restore's JavaScript reply (U-Q25).
    var quickUndoReplyHold: (() async -> Void)?
    /// Every quick undo / quick redo / resume script the editor received, in order.
    var quickUndoScripts: [String] = []
    var quickRedoScripts: [String] = []
    var resumeScripts: [String] = []
    /// How many times `getContent()` was asked of the editor.
    var getContentCalls = 0
    /// How many `pushBlockIds` calls the controller made (the push itself is replaced by `testPushBlockIdsHook`).
    var pushBlockIdsCalls = 0
    /// The editor's live Markdown as the quick path models it: the pre-delete checkpoint after a quick restore, the document without
    /// the section after a quick redo, plus whatever `typeIntoEditor` added. `getContent()` answers it when `fetchAnswerProvider` has
    /// no answer. nil: the quick path has not touched the editor.
    var quickEditorText: String?
    /// `contentChanged`, as the rig produces it: the editor tells Swift its live text (`editorState.content = ...`) shortly after
    /// `resumeSyncAfterQuickUndo` and after `typeIntoEditor`. This flag withholds BOTH: the notification never arrives, and `content`
    /// stays what it was (the post-delete text), the case the reinsert settle must not trust (U-Q18).
    var withholdContentUpdate = false
    /// Edits the page holds and has not reported yet, oldest first (`queueTyping`). Phase 5 B4: each leaves as one report
    /// (`postQueuedTyping`) when the page's debounce would post it (`startReport`) or when Swift asks (`flushReports`).
    var typingQueue: [BlockChanges] = []
    /// The report numbers the rig's page has posted so far, in its one page session (`reportSession`).
    var reportsPosted = 0
    static let reportSession = "rig-page"
    /// The page does not answer the next `flushReports` (a wedged page), once.
    var wedgeNextFlushReports = false
    /// How many times Swift asked the page `flushReports` (step F of a close, a rebuild's flush).
    var flushReportsCalls = 0
    /// What `ContentView`'s content-change handler does with the footnote service when `content` changes while the editor is idle.
    /// Off unless a test turns it on: only the footnote-checkpoint tests need it.
    var emulatesFootnoteContentChange = false
    /// The find bar the controller was configured with (the quick undo, the quick redo and the delete click clear its search).
    let findBar = FindBarState()
    /// What the editor answers to `quickUndoLiveDiffersFromRestored(opId)` (S1-7): nil derives it (the live text differs from the text the
    /// quick restore put back, i.e. the user typed during the undo); a value forces the answer.
    var liveDiffersOverride: Bool?
    /// The text the last quick restore put into the editor.
    var lastRestoredText: String?
    /// Awaited INSIDE the answer to `getContent()`, after the answer was computed: the real reply is as old as its JavaScript turn, however
    /// late it arrives (U-Q29, U-Q29b).
    var getContentHold: (() async -> Void)?
    /// Awaited inside the answer to `redoSectionDeleteEditorFirst`, before it is returned (U-Q31).
    var quickRedoReplyHold: (() async -> Void)?

    // MARK: Editor-first structural operations other than delete (t-18b7fa48 round 1e-i; EditorFirstRig+StructuralQueue.swift answers them)

    /// The pending edits the next `duplicateSectionEditorFirst` call consumes and returns as its `batch` (typing up to the click). nil:
    /// an empty batch. Spent by the call.
    var duplicateClickBatch: BlockChanges?
    /// Makes the next editor-first structural job fail, the way a database fault would (round 1g-A, review T1): the duplicate's answer
    /// installs a trigger that aborts the insert of the copy's rows, so the queued job throws while it copies, its transaction (the
    /// Version History snapshot included) rolls back, and the database is left EXACTLY as it was: the section's root row is still
    /// there, which the earlier seam (it deleted the root row) could not say. Spent by the call. (`testFailedJobPutsTheSectionBack`
    /// fails a delete job by retiring the writer instead, which also refuses every later poll; a put-back that must keep typing from
    /// after the click needs the writer alive.)
    var forceNextJobFailure = false
    /// The editor answers the next Duplicate Section click `ok:false`, reason `rootNotFound` (round 1g-A, review A7): its own id for
    /// the root heading is still a temporary one, although the database row and the sidebar are confirmed. Like every editor answer it
    /// still hands back the batch it consumed. Spent by the call.
    var forceEditorRootNotFound = false
    /// The editor's reply to the next Duplicate Section click lists one MORE copy than the section has nodes in the table, a copy of a
    /// node the table has no row for (round 1g-C, review A2: an editor node whose id the rows lack). The job then reports that the
    /// copies and the rows differ, and the settle pushes the database's ids to the editor. Spent by the call.
    var duplicateReplyAddsCopyWithoutRow = false
    /// Models what the real editor does with a WHOLE-document push (`setContentWithBlockIds` without `preserveUserBlocks`: the D6
    /// put-back): `editorText` becomes the pushed text. Off by default (a push leaves `editorText` alone, as before), so only the
    /// tests that look at what the put-back leaves ON THE SCREEN turn it on (round 1g-A, review T1).
    var modelsWholePushOnEditor = false
    /// Keystrokes the user makes WHILE the next whole-document push is in flight (the editor's block-sync is paused for it). The real
    /// editor keeps them as pending changes only when the push asked for `detectPausedEdits`; otherwise the replace discards them. The
    /// rig does the same: kept, they are in `editorText` and queued for the next poll; not kept, they are gone. Spent by the push.
    var typedDuringNextWholePush: (block: Block, suffix: String)?
    /// Every `duplicateSectionEditorFirst(...)` and `redoSectionDuplicateEditorFirst(...)` script the editor received, in order.
    var duplicateScripts: [String] = []
    var redoDuplicateScripts: [String] = []
    /// What each Duplicate Section click's editor held, by operation id: what the quick undo of the duplicate answers.
    var duplicateClicks: [String: DuplicateClick] = [:]
    /// The editor refuses the next Duplicate Section click (`ok:false`, reason `managedRoot`) and, as the real one does on every path,
    /// still hands back the batch it consumed (`duplicateClickBatch`). Spent by the call (round 1e-ii, U-S1-9).
    var forceEditorRefusal = false
    /// How the stand-in editor works out the document it holds after a duplicate (round 1e-ii). false (the default): from the database's
    /// rows plus the copy, which is right whenever the database and the editor agree. true: from the editor's OWN text (`editorText`, else
    /// `quickEditorText`) with the copy inserted right after the original section's text, which is what the real editor does and what a
    /// test needs when the editor's Notes differ from the database's (a delete's half-updated Notes) or when the editor holds a section
    /// the database does not have yet (a quick undo whose reinsert is still pending).
    var duplicateInsertsIntoEditorText = false
    /// The editor refuses the next quick REDO of a duplicate (`ok:false`, with this reason; the batch is empty, as a redo consumes none
    /// that matters). Spent by the call (round 1g-B, review A3: the redo's abandon exits).
    var refuseNextDuplicateRedoWith: String?
    // MARK: Editor-first Version History restore (t-18b7fa48 Phase 4b slice 2, round 2d-i; EditorFirstRig+StructuralQueue.swift answers it)

    /// The pending edits the next `replaceRangeEditorFirst` call consumes and returns as its `batch` (typing up to the click). nil: an
    /// empty batch. Spent by the call. (The refusal and job-failure switches are the duplicate's: `forceEditorRefusal`,
    /// `forceNextJobFailure`; the restore's answer spends them too.)
    var replaceClickBatch: BlockChanges?
    /// Every `replaceRangeEditorFirst(...)` and `redoReplaceRangeEditorFirst(...)` script the editor received, in order.
    var replaceScripts: [String] = []
    var redoReplaceScripts: [String] = []
    /// What each restore click's editor held, by operation id: what the quick undo of the restore answers.
    var replaceClicks: [String: ReplaceClick] = [:]
    // MARK: Editor-first slow undo and redo (t-18b7fa48 Phase 4b slice 3, round 3c; EditorFirstRig+SlowUndo.swift answers it)

    /// The pending edits the next `structuralSwapEditorFirst` call consumes and returns as its `batch`, on EVERY path (typing up to the
    /// call). nil: an empty batch. Spent by the call.
    var swapClickBatch: BlockChanges?
    /// The editor answers the next swap `ok:false`, reason `docChanged` (the page found the document changed by an automatic update, or a
    /// typed step with no place in the target; typing alone no longer refuses, t-d2061b27): nothing is swapped, and the batch is still
    /// handed back. Spent by the call.
    var swapLiveDiffers = false
    /// t-d2061b27: the stand-in's switches for typing across a waiting press (replayed typing, held typing, the batch of a redo): one state
    /// object; the switches are forwarded as properties of the rig in EditorFirstRig+TypingAcrossUndo.swift.
    let typingStubs = TypingAcrossUndoStubState()
    /// The editor answers the next swap `ok:false`, reason `noCheckpoint` (no saved state for the entry). Spent by the call.
    var swapAnswerNoCheckpoint = false
    /// The editor answers the next swap `ok:false`, reason `idAlignment` (the payload does not fit the saved document). Spent by the call.
    var swapAnswerIdAlignment = false
    /// Every `structuralSwapEditorFirst(...)` script the editor received, in order.
    var swapScripts: [String] = []
    /// `getContentCalls` at the moment the latest swap script was answered: how many live-content reads came BEFORE the swap.
    var getContentCallsAtSwap: Int?
    /// Runs inside the answer to the next `structuralSwapEditorFirst` call, after it is recorded and before it is answered. Spent by the call.
    var onSwapAnswered: (() -> Void)?

    /// The always-persisted log lines of THIS rig (see `logScope`).
    var persistedLog: [String] { logScope.lines }

    /// Leader ids the editor's reply to the quick UNDO of a duplicate lists in `removedLeaderIds` besides the copy's own (round 1g-B,
    /// review A5). The real editor lists "the live leaders whose id the checkpoint's id map lacks" (api-section-undo.ts); after a
    /// flush that re-minted the ids of non-heading blocks (the idle backup, Save Version, export) that is every section break of the
    /// document, the original sections' too. Empty: the reply lists the copy's leaders only.
    var undoAlsoReportsRemoved: [String] = []

    struct Push {
        let markdown: String
        let blockIds: [String]
        let managedBlockIds: Set<String>
        let preserveUserBlocks: Bool
        /// `editorState.isResettingContent` at the moment the push ran: the flag that keeps the view from pushing `content` meanwhile.
        let isResettingContent: Bool
        /// `editorState.content` at the moment the push ran: what the view would push if it were allowed to. After a quick undo it must
        /// be the EDITOR's own text, never the database's text the push is about to bring in (verdict-v4 V2).
        var contentAtPush: String = ""
        /// The push's `detectPausedEdits` option (round 1g-A, review T1).
        var detectPausedEdits = false
    }

    /// Models the view's rule that `editorState.content`, when it differs from what the editor was last given, is pushed into the
    /// editor on the next view update UNLESS `isResettingContent` is set (`MilkdownEditor.updateNSView` -> `setContent`, guarded by
    /// that flag in every rebuild handler). With it on, a merge-guarded push that runs while `isResettingContent` is false first
    /// replaces `editorText` with `editorState.content`, as the real view would have; with the flag set it does not. Off by default:
    /// only the tests that pin the closing push need the rule.
    var modelsViewPushOfContent = false

    /// `configureSyncServices: false` leaves the footnote and bibliography services without a database (their resyncs then do
    /// nothing): the book-sized documents carry hundreds of citations, whose real rebuild is not what these tests are about.
    ///
    /// `lifecycleServices: true` wires the two services the way `ContentView` does: they write through the writer's queue
    /// (`systemWriter`) and are the editor state's own, so a close or quit suspends them at step 0 and refreshes them at step 7.
    /// Off by default: the delete's other tests have no use for their queue writes, and an unrelated parked write (U11) would
    /// hold them up.
    init(markdown: String, configureSyncServices: Bool = true, lifecycleServices: Bool = false) throws {
        db = try TestFixtureFactory.createTemporary(content: markdown)
        let projectId = try TestFixtureFactory.getProjectId(from: db)
        pid = projectId
        logScope = RigLogScope(projectId: projectId)
        sync.configure(database: db, projectId: pid, webView: view)
        sync.editorState = editorState
        editorState.toastCenter = toasts
        editorState.blockSyncService = sync
        editorState.projectDatabase = db
        editorState.currentProjectId = pid
        editorState.content = markdown
        if configureSyncServices {
            bibliography.configure(database: db, projectId: pid)
            footnotes.configure(database: db, projectId: pid)
        }
        if lifecycleServices {
            bibliography.systemWriter = SystemWriter(blockSync: sync)
            footnotes.systemWriter = SystemWriter(blockSync: sync)
            editorState.bibliographySyncService = bibliography
            editorState.footnoteSyncService = footnotes
        }
        controller.configure(
            editorState: editorState, blockSyncService: sync, sectionSyncService: SectionSyncService(),
            bibliographySyncService: bibliography, footnoteSyncService: footnotes,
            annotationSyncService: AnnotationSyncService(), unifiedUndoService: unifiedUndo, findBarState: findBar)
        // The closures below hold the rig WEAKLY (slice 2b): a test that ends early (a failed `#require`, which is what a targeted break
        // makes a test do) leaves background tasks of the controller running, and those must find a rig that is gone, not crash on it.
        installScriptedEditor()
    }

    /// Hands the controller's and the sync service's test seams to the scripted editor (`EditorFirstRig+QuickUndo.swift` answers). The
    /// closures hold the rig WEAKLY (slice 2b): a test that ends early (a failed `#require`, which is what a targeted break makes a
    /// test do) leaves background tasks of the controller running, and those must find a rig that is gone, not crash on it.
    private func installScriptedEditor() {
        controller.testEvalBoolOverride = { [weak self] js in
            self?.answerEvalBool(js) ?? StructuralUndoControllerTests.realisticEvalBoolDefault(js)
        }
        controller.testEvalVoidOverride = { [events, weak self] js in
            events.note("js " + js)
            if js.contains("resumeSyncAfterQuickUndo") { self?.noteResume(js) }
            return true
        }
        controller.testOrderingSpy = { [spyLog] step in spyLog.note(step) }
        controller.presentAlert = { [weak self] alert in self?.alerts.append(alert) }
        sync.testPushBlockIdsHook = { [events, weak self] _ in
            self?.pushBlockIdsCalls += 1
            events.note("pushBlockIds")
        }
        sync.testSetContentHook = { [weak self] markdown, blockIds, managed, preserve in
            self?.recordPush(markdown: markdown, blockIds: blockIds, managed: managed, preserve: preserve)
                ?? (preserve ? markdown : nil)
        }
        sync.testJSEvaluator = { [weak self] script in try await self?.answerScript(script) }
    }

    /// The text the Rich Text editor holds after a merge-guarded push: its own blocks (everything before the `# Notes` heading) and the
    /// database's Notes and Bibliography (everything from that heading on), which is where the fixtures keep the managed regions.
    static func mergingManagedRegions(editor: String, database: String) -> String {
        guard let editorNotes = editor.range(of: "\n# Notes\n"), let databaseNotes = database.range(of: "\n# Notes\n") else {
            return database
        }
        return String(editor[..<editorNotes.lowerBound]) + String(database[databaseNotes.lowerBound...])
    }

    func setReply(_ reply: EditorFirstReply) throws {
        deleteReply = try JSONEncoder().encode(reply)
    }

    /// The reply for a Delete Section whose call names `rootId`.
    func setReply(_ reply: EditorFirstReply, forRoot rootId: String) throws {
        repliesByRoot[rootId] = try JSONEncoder().encode(reply)
    }

    /// The document as the database holds it, in the form the editor shows (what `editorState.content` is in a real session).
    func assembledMarkdown() throws -> String {
        let sorted = try blocks().sorted { lhs, rhs in
            (lhs.sortOrder, lhs.blockType == .heading ? 0 : 1) < (rhs.sortOrder, rhs.blockType == .heading ? 0 : 1)
        }
        return BlockParser.assembleMarkdownForEditor(from: sorted)
    }

    /// Makes `editorState.content` say what the database says, as the editor's own `contentChanged` pushes do in a real session.
    /// The editor-first delete changes the database in the background and these tests have no real editor, so the old path's
    /// flush (which writes `editorState.content`) would otherwise write the document as it was before the delete.
    func syncEditorContentFromDatabase() throws {
        editorState.content = try assembledMarkdown()
    }

    /// The level-1 headings that are not Notes or Bibliography, in document order.
    func chapterHeadings() throws -> [Block] {
        try blocks()
            .filter { $0.blockType == .heading && $0.headingLevel == 1 && !$0.isNotes && !$0.isBibliography }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Reserves an editor ticket that never fetches or applies anything: every sequence reserved after it (the delete job
    /// included) waits behind it, so a test can hold the job "queued but not yet run" without blocking a thread. Release it with
    /// `release(_:)`.
    func holdQueue() throws -> WriterTicket {
        try #require(sync.testWriterHandle).reserve()
    }

    func release(_ ticket: WriterTicket) {
        ticket.settleIfOpen(.noBatch)
    }

    /// Rewrites one block row's text directly in the database (what an applied bibliography or Notes rebuild does).
    func rewriteText(ofBlock id: String, to text: String) throws {
        try rewriteRow(db: db, id: id, text: text)
    }

    // MARK: Lifecycle

    /// The host the lifecycle save sequence is handed: only `activeWebView` and the toast center do anything.
    func lifecycleHost() -> LifecycleHost {
        LifecycleHost(
            activeWebView: { [view] in view },
            runOpenTail: { _ in },
            runCreateTail: { _, _ in },
            runCloseTail: { _, _ in },
            repostDeferredRebuilds: {},
            scheduleSourceModeReparse: { _ in },
            toastCenter: { [toasts] in toasts }
        )
    }

    /// Arms a token of `kind`, runs the lifecycle save sequence against it and clears everything the way `LifecycleEntry` does
    /// afterwards (the writer barrier released, the token cleared, the structural gate open again).
    func runLifecycle(
        _ kind: LifecycleKind, bounds: LifecycleBounds, sourceLocation: SourceLocation = #_sourceLocation
    ) async -> LifecycleFlushResult {
        guard case .armed(let token) = editorState.armLifecycle(kind, wasGettingStarted: false) else {
            Issue.record("the rig could not arm a \(kind) token", sourceLocation: sourceLocation)
            return LifecycleFlushResult()
        }
        let deadline = LifecycleDeadline(total: kind == .quit ? bounds.quitTotal : bounds.closeTotal)
        let result = await editorState.runLifecycleFlush(
            token: token, host: lifecycleHost(), structuralUndoController: controller, deadline: deadline, bounds: bounds)
        // `LifecycleEntry.finish` and `abortLifecycle` leave the barrier and the structural gate alone when a quit joined this
        // lifecycle and replaced its token: the quit owns them until the process exits (#18). A joined quit that is still running
        // (a test that arms one by hand) must keep them too, or the gate reopens under it and forgets the allowance it holds.
        let quitTookOver = editorState.activeLifecycle.map { $0.id != token.id && $0.kind == .quit } ?? false
        if !quitTookOver {
            editorState.lifecycleBarrier?.release()
            editorState.lifecycleBarrier = nil
            editorState.structuralGate.isClosedToNewWork = false
        }
        editorState.clearLifecycle(token.id)
        return result
    }

    /// The scripts the controller sent to the editor that contain `fragment`, in order.
    func scripts(containing fragment: String) -> [String] {
        events.items.filter { $0.hasPrefix("js ") && $0.contains(fragment) }
    }

    func blocks() throws -> [Block] {
        try db.fetchBlocks(projectId: pid)
    }

    /// The heading block of the section titled `title`.
    func heading(_ title: String) throws -> Block {
        try #require(try blocks().first { $0.blockType == .heading && $0.textContent == title })
    }

    /// Waits for the entry's job to end and for the work that follows it.
    func settle(_ opId: UUID) async {
        _ = await editorState.efJobRegistry.awaitOutcome(opId)
        if let task = controller.efSettleTasks[opId] { await task.value }
    }
}

/// Rewrites a block row's text. A plain (non-async) function on purpose: inside an `async` test `dbWriter.write` resolves to
/// GRDB's async overload.
@MainActor
private func rewriteRow(db: ProjectDatabase, id: String, text: String) throws {
    _ = try db.dbWriter.write { database in
        try Block.filter(key: id).updateAll(
            database, Block.Columns.textContent.set(to: text), Block.Columns.markdownFragment.set(to: text))
    }
}

/// The stored write stamp of a block row. A plain (non-async) function on purpose: inside an `async` test, `dbWriter.read`
/// resolves to GRDB's async overload.
@MainActor
private func storedStamp(_ rig: EditorFirstRig, _ blockId: String) throws -> BlockWriteStamp? {
    try rig.db.dbWriter.read { database in
        try ProjectDatabase.storedStamp(db: database, blockId: blockId)
    }
}

@Suite("Editor-first Delete Section — Phase 4b slice 2a (Tier 2)", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct EditorFirstDeleteTests {

    /// U5 / U14's must-fail switches (the driver flips them for the must-fail proofs; both ship `false`):
    ///   - `useLegacyDelete`: U5 then fails with `spy contained "modeAwareFlush"`.
    ///   - `bumpGenerationAtClick` (addendum A10): U14 then fails with `expected block text to contain "TYPED-U14"`.
    ///     NEVER use the legacy flag for U14's old shape: the legacy flush heals the very loss it looks for.
    static let useLegacyDelete = false
    static let bumpGenerationAtClick = false

    private static let threeSections = """
    # First Chapter

    The first chapter's body.

    ## Second Section

    The second section's body.

    ## Third Section

    The third section's body.
    """

    // MARK: - U5

    @Test("U5: Delete Section on the article is editor-first: no flush, no undo-point copy, no whole-document push; the job removes the rows")
    func testEditorFirstDeleteOnArticle() async throws {
        let rig = try EditorFirstRig(markdown: ComplexDocumentFixture.article.seedMarkdown)
        rig.controller.testForceLegacyDelete = Self.useLegacyDelete
        let rows = try rig.blocks()
        let root = try #require(
            rows.first { $0.blockType == .heading && $0.headingLevel == 2 && !$0.isNotes && !$0.isBibliography }
                ?? rows.first { $0.blockType == .heading && !$0.isNotes && !$0.isBibliography })
        let subtreeIds = try #require(try rig.db.sectionBlockIds(rootId: root.id, projectId: rig.pid))
        #expect(!subtreeIds.isEmpty)
        try rig.setReply(.init(removedLeaderIds: [root.id]))

        let outcome = await rig.controller.performSectionDelete(rootId: root.id)

        #expect(outcome == .performed)
        let steps = rig.spyLog.items
        #expect(!steps.contains("modeAwareFlush"), "spy contained \"modeAwareFlush\": \(steps)")
        #expect(!steps.contains("createUndoPointSnapshot"), "spy contained \"createUndoPointSnapshot\": \(steps)")
        #expect(!steps.contains("finalizeStructuralOpPostOpDoc"), "spy contained \"finalizeStructuralOpPostOpDoc\": \(steps)")
        #expect(steps.contains("efJS"), "the editor-first JS call must have run: \(steps)")
        let reserved = try #require(steps.firstIndex(of: "efReservedJob"))
        let recorded = try #require(steps.firstIndex(of: "efRecorded"))
        let called = try #require(steps.firstIndex(of: "efJS"))
        #expect(called < reserved && reserved < recorded, "order must be: JS call, job reserved, entry recorded: \(steps)")

        // The Edit menu says "Undo Delete Section" at once, before the job has applied anything.
        let entry = try #require(rig.unifiedUndo.undoStack.last)
        #expect(entry.kind == .sectionDelete)
        #expect(entry.undoSnapshotId == nil, "an editor-first delete carries no snapshot id on its entry")

        await rig.settle(entry.id)

        // After the job: the section rows are gone, the Version History copy exists and is pinned, the sidebar filter is lifted.
        let remaining = Set(try rig.blocks().map(\.id))
        #expect(remaining.isDisjoint(with: subtreeIds), "the section's rows must be gone after the job")
        let slot = try #require(rig.controller.efSlots.slot(entry.id))
        let snapshotId = try #require(slot.snapshotId)
        defer { SnapshotService.unpinUndoPointSnapshot(snapshotId) }
        #expect(SnapshotService.isUndoPointSnapshotPinned(snapshotId))
        #expect(rig.editorState.pendingRemovalIds.isEmpty)
    }

    // MARK: - U14

    @Test("U14: a report admitted BEFORE the click (its turn reserved, not yet applied) survives the delete")
    func testPollBatchFetchedBeforeClickSurvives() async throws {
        let rig = try EditorFirstRig(markdown: Self.threeSections)
        rig.controller.testEFBumpGenerationAtClick = Self.bumpGenerationAtClick
        let paragraph = try #require(try rig.blocks().first { $0.blockType == .paragraph && $0.textContent == "The first chapter's body." })
        let root = try rig.heading("Second Section")
        let subtreeIds = try #require(try rig.db.sectionBlockIds(rootId: root.id, projectId: rig.pid))

        // A report carrying the user's typing is admitted (its turn reserved) while the writer is busy, so it has not applied yet.
        let typed = BlockChanges(updates: [BlockUpdate(
            id: paragraph.id, textContent: "The first chapter's body. TYPED-U14", markdownFragment: "The first chapter's body. TYPED-U14",
            headingLevel: nil)])
        let busy = try #require(rig.sync.writer).reserve()
        rig.sync.reportApplier.receive(
            IncomingReport(number: 1, session: EditorFirstRig.reportSession, changes: typed, detectedAt: 0), via: .message)
        #expect(rig.sync.reportApplier.testLedger(EditorFirstRig.reportSession).waiting == [1],
                "the report must hold its turn before the click")

        // The click: its own batch is empty (the report took the typing), and it removes the section.
        try rig.setReply(.init(removedLeaderIds: [root.id]))
        let outcome = await rig.controller.performSectionDelete(rootId: root.id)
        #expect(outcome == .performed)
        let entry = try #require(rig.unifiedUndo.undoStack.last)

        busy.settleIfOpen(.empty)
        await rig.settle(entry.id)

        let rows = try rig.blocks()
        let text = rows.first { $0.id == paragraph.id }?.textContent ?? ""
        #expect(text.contains("TYPED-U14"), "expected block text to contain \"TYPED-U14\", got \"\(text)\"")
        #expect(Set(rows.map(\.id)).isDisjoint(with: subtreeIds), "the section rows must be gone")
    }

    // MARK: - U16

    @Test("U16: the click reserves ticket N with a write stamp, and the batch it consumed applies carrying it")
    func testClickReservesWithStamp() async throws {
        let rig = try EditorFirstRig(markdown: Self.threeSections)
        let paragraph = try #require(try rig.blocks().first { $0.blockType == .paragraph && $0.textContent == "The first chapter's body." })
        let root = try rig.heading("Second Section")
        let typed = BlockChanges(updates: [BlockUpdate(
            id: paragraph.id, textContent: "The first chapter's body. STAMPED", markdownFragment: "The first chapter's body. STAMPED",
            headingLevel: nil)])
        try rig.setReply(.init(batch: typed, removedLeaderIds: [root.id]))

        let outcome = await rig.controller.performSectionDelete(rootId: root.id)
        #expect(outcome == .performed)
        let entry = try #require(rig.unifiedUndo.undoStack.last)
        await rig.settle(entry.id)

        let rows = try rig.blocks()
        #expect(rows.first { $0.id == paragraph.id }?.textContent.contains("STAMPED") == true, "the click's own batch must be applied")
        let stamp = try storedStamp(rig, paragraph.id)
        #expect(stamp != nil, "an editor batch applied by the click must carry a non-nil write stamp")
    }

    // MARK: - ok == false

    @Test("The editor refusing the removal (ok false) leaves the section alone, applies the batch it consumed, and reports a refusal")
    func testEditorRefusalAppliesBatchAndRefuses() async throws {
        let rig = try EditorFirstRig(markdown: Self.threeSections)
        let paragraph = try #require(try rig.blocks().first { $0.blockType == .paragraph && $0.textContent == "The first chapter's body." })
        let root = try rig.heading("Second Section")
        let typed = BlockChanges(updates: [BlockUpdate(
            id: paragraph.id, textContent: "The first chapter's body. KEPT", markdownFragment: "The first chapter's body. KEPT",
            headingLevel: nil)])
        // Round 1g-B: the refusal this test sends is `managedRoot` (the editor's own managed set says the root is Notes or Bibliography,
        // a stale set: the database agrees it is a section). It used to be `rootNotFound`; round 1g-A (review A7) made that reply behave
        // like `noEditor` (nothing changed, the old sequence takes the press: `testRootNotFoundReplyDeletesTheSectionTheOldWay`), so it
        // is no longer a refusal. `managedRoot` still is one in production (web/milkdown/src/api-section-delete.ts).
        try rig.setReply(.init(batch: typed, succeeded: false, reason: "managedRoot", removedLeaderIds: []))

        let outcome = await rig.controller.performSectionDelete(rootId: root.id)

        #expect(outcome == .refused)
        #expect(rig.unifiedUndo.undoStack.isEmpty, "a refused delete records nothing")
        #expect(rig.editorState.efJobRegistry.outstandingCount == 0, "no job may be queued for a refused delete")
        // The consumed batch is applied (the editor already cleared its queue): wait for the writer to apply it.
        var applied = false
        for _ in 0..<400 where !applied {
            applied = try rig.blocks().first { $0.id == paragraph.id }?.textContent.contains("KEPT") == true
            if !applied { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(applied, "the batch the call consumed must still reach the database")
        let stillThere = try rig.blocks().contains { $0.id == root.id }
        #expect(stillThere, "the section is still in the database")
    }

    // Round 1g-B (the Delete twin of the Duplicate test of round 1g-A, review A7, in EditorFirstDuplicateOverlayTests): the editor answers
    // `rootNotFound` (its own id for the root heading is still a temporary one, although the database row and the sidebar entry are
    // confirmed). The call changed nothing, so the press goes on the old way and the section is deleted; it is not refused with
    // "Couldn't Delete Section ... Nothing was changed".
    @Test("A7 (Delete): a rootNotFound reply sends the press down the old way: the section is deleted, nothing is refused, no alert shows")
    func testRootNotFoundReplyDeletesTheSectionTheOldWay() async throws {
        let rig = try EditorFirstRig(markdown: Self.threeSections)
        let snapshots = SnapshotService(database: rig.db, projectId: rig.pid)
        defer { for snapshot in (try? snapshots.fetchAllSnapshots()) ?? [] { SnapshotService.unpinUndoPointSnapshot(snapshot.id) } }
        let root = try rig.heading("Second Section")
        try rig.setReply(.init(succeeded: false, reason: "rootNotFound"), forRoot: root.id)

        let outcome = await rig.controller.performSectionDelete(rootId: root.id)

        #expect(outcome == .performed, "Delete Section on a heading the editor has no id for yet ended \(outcome)")
        #expect(rig.deleteScripts.count == 1, "the editor was asked \(rig.deleteScripts.count) times")
        #expect(!rig.scripts(containing: "beginStructuralOp").isEmpty, "the old whole sequence did not run")
        let texts = try rig.blocks().map(\.textContent)
        #expect(!texts.contains("Second Section") && !texts.contains("The second section's body."), "the section is still in the table: \(texts)")
        #expect(texts.contains("First Chapter") && texts.contains("Third Section"), "a neighbouring section was removed too: \(texts)")
        #expect(rig.alerts.isEmpty, "an alert was raised: \(rig.alerts)")
        #expect(rig.editorState.pendingEditorFirstJobs == 0, "the pending count stayed up")
        #expect(rig.editorState.efJobRegistry.outstandingCount == 0, "no editor-first job may be queued for a press the old sequence carried out")
        let entry = try #require(rig.unifiedUndo.undoStack.last, "the delete was not recorded")
        #expect(rig.unifiedUndo.undoStack.count == 1 && entry.kind == .sectionDelete, "got \(rig.unifiedUndo.undoStack)")
        #expect(entry.undoSnapshotId != nil, "the entry must be the old path's (it carries an undo snapshot), not an editor-first one")
    }

    // MARK: - U6

    @Test("U6: a job that does not apply puts the section back from the database, clears the entry, slot and pin, and tells the user")
    func testFailedJobPutsTheSectionBack() async throws {
        let rig = try EditorFirstRig(markdown: Self.threeSections)
        let root = try rig.heading("Second Section")
        try rig.setReply(.init(removedLeaderIds: [root.id]))
        // An earlier editor sequence that never settles holds the job's turn, so the job is queued but cannot run yet.
        let writer = try #require(rig.sync.testWriterHandle)
        let blocker = writer.reserve()
        defer { blocker.settleIfOpen(.noBatch) }

        let outcome = await rig.controller.performSectionDelete(rootId: root.id)
        #expect(outcome == .performed)
        let opId = try #require(rig.unifiedUndo.undoStack.last?.id)
        // The project switches before the job's turn: the writer is retired and skips the queued job, which therefore never
        // applies. (The editor's own view is dropped so the put-back's push has nothing to talk to in this test.)
        rig.sync.testClearOwnWebView()
        rig.sync.retireWriterForLifecycle(reason: .projectSwitch)
        await rig.settle(opId)

        let stillThere = try rig.blocks().contains { $0.id == root.id }
        #expect(stillThere, "the job did not apply, so the database still holds the section")
        #expect(rig.unifiedUndo.undoStack.isEmpty, "D6 removes the entry")
        #expect(rig.controller.efSlots.slot(opId) == nil, "D6 removes the slot")
        #expect(rig.editorState.pendingRemovalIds.isEmpty, "D6 lifts the sidebar filter")
        #expect(rig.alerts.count == 1, "the user is told: \(rig.alerts)")
        #expect(rig.alerts.first?.title == "Couldn't Delete Section")
        // Item 9: the alert says what happened and makes no promise that nothing was lost (the put-back can overwrite last-moment typing).
        #expect(rig.alerts.first?.message.contains("Nothing was lost") == false, "got \(rig.alerts)")
        #expect(rig.alerts.first?.message.contains("put back") == true, "got \(rig.alerts)")

        // Item 17: the put-back really pushed the database's document into the editor, as a whole-content push (not merge-guarded).
        let putBackPushes = rig.pushes.filter { !$0.preserveUserBlocks }
        #expect(putBackPushes.count == 1, "exactly one whole-content push: \(rig.pushes.count) pushes in all")
        #expect(putBackPushes.first?.markdown.contains("Second Section") == true, "the pushed document holds the section again")

        // Item 12: a Cmd-Z that was already on its way for the entry D6 removed is answered `failed`, never `fallback` (a plain
        // text undo would remove the user's last typing after the section was put back).
        await rig.controller.handleStructuralRequest(opId: opId.uuidString, direction: .undo)
        let reply = try #require(rig.scripts(containing: "receiveUndoOutcome").last)
        #expect(reply.contains("'failed'"), "got \(reply)")
    }

    // MARK: - Item 10 (R10a): the editor's removedIds against the rows the job deleted

    @Test("R10a: removedIds that disagree with the rows the job deleted are logged (alwaysPersisted) and change nothing else")
    func testMismatchedRemovedIdsAreLoggedAndChangeNothing() async throws {
        let rig = try EditorFirstRig(markdown: Self.threeSections)
        let root = try rig.heading("Second Section")
        let subtreeIds = try #require(try rig.db.sectionBlockIds(rootId: root.id, projectId: rig.pid))
        #expect(subtreeIds.count >= 2, "the section has a heading and a body row")
        // The editor says it removed every row but the last one, and one row the database never had.
        let keptOnScreen = try #require(subtreeIds.last)
        let ghost = "ghost-row-only-the-editor-had"
        var reply = EditorFirstReply(removedLeaderIds: [root.id])
        reply.removedIds = Array(subtreeIds.dropLast()) + [ghost]
        try rig.setReply(reply)
        let capture = AlwaysLogCapture()
        DebugLog.alwaysSink = { capture.append($0) }
        defer { DebugLog.alwaysSink = nil }

        let outcome = await rig.controller.performSectionDelete(rootId: root.id)
        #expect(outcome == .performed)
        let entry = try #require(rig.unifiedUndo.undoStack.last)
        await rig.settle(entry.id)

        // The mismatch was written to the persistent log, naming both sides.
        let lines = capture.captured.filter { $0.contains(entry.id.uuidString) && $0.contains("the editor removed") }
        #expect(lines.count == 1, "exactly one mismatch line for this delete: \(capture.captured)")
        #expect(lines.first?.contains(ghost) == true, "the row only the editor removed is named: \(lines)")
        #expect(lines.first?.contains(keptOnScreen) == true, "the row only the job deleted is named: \(lines)")

        // Nothing else changed: the job deleted the whole section and the delete finished as it does for matching ids.
        let remaining = Set(try rig.blocks().map(\.id))
        #expect(remaining.isDisjoint(with: Set(subtreeIds)), "every row of the section is gone, whatever the editor reported")
        #expect(rig.unifiedUndo.undoStack.map(\.id) == [entry.id], "the entry stays recorded: the delete is undoable")
        let slot = try #require(rig.controller.efSlots.slot(entry.id))
        let snapshotId = try #require(slot.snapshotId)
        defer { SnapshotService.unpinUndoPointSnapshot(snapshotId) }
        #expect(SnapshotService.isUndoPointSnapshotPinned(snapshotId))
        #expect(rig.alerts.isEmpty, "a mismatch is a diagnostic, never an alert")
        #expect(rig.editorState.pendingRemovalIds.isEmpty)
    }

    @Test("R10a: removedIds that agree with the rows the job deleted write no mismatch line")
    func testMatchingRemovedIdsLogNothing() async throws {
        let rig = try EditorFirstRig(markdown: Self.threeSections)
        let root = try rig.heading("Second Section")
        let subtreeIds = try #require(try rig.db.sectionBlockIds(rootId: root.id, projectId: rig.pid))
        var reply = EditorFirstReply(removedLeaderIds: [root.id])
        reply.removedIds = subtreeIds
        try rig.setReply(reply)
        let capture = AlwaysLogCapture()
        DebugLog.alwaysSink = { capture.append($0) }
        defer { DebugLog.alwaysSink = nil }

        let outcome = await rig.controller.performSectionDelete(rootId: root.id)
        #expect(outcome == .performed)
        let entry = try #require(rig.unifiedUndo.undoStack.last)
        await rig.settle(entry.id)

        #expect(
            !capture.captured.contains { $0.contains(entry.id.uuidString) && $0.contains("the editor removed") },
            "the editor and the job agree: nothing to report: \(capture.captured)")
        if let snapshotId = rig.controller.efSlots.slot(entry.id)?.snapshotId { SnapshotService.unpinUndoPointSnapshot(snapshotId) }
    }

    @Test("Item 14 / R2: a noEditor reply falls through to the old sequence, which also finds no editor and refuses: nothing is deleted or recorded")
    func testNoEditorReplyFallsThroughToTheOldSequenceWhichRefusesToo() async throws {
        // `noEditor` means there is no editor instance yet. The old sequence's own `beginStructuralOp` call answers false in the same
        // situation, so the press ends `.refused`; `ContentView.deleteSectionFromSidebar` turns `.refused` into the "Couldn't Delete
        // Section" alert (ContentView+SectionOperations.swift), which a controller-level test cannot show. What it can pin is
        // everything up to that point: the old sequence ran, stopped at the editor, and changed nothing. (Before R2 this test let the
        // stub answer true for `beginStructuralOp`, so the old sequence "succeeded" and the test passed vacuously.)
        let rig = try EditorFirstRig(markdown: Self.threeSections)
        rig.beginStructuralOpAnswer = false
        let root = try rig.heading("Second Section")
        let rowsBefore = try rig.blocks().sorted { $0.sortOrder < $1.sortOrder }
        try rig.setReply(.init(succeeded: false, reason: "noEditor"))

        let outcome = await rig.controller.performSectionDelete(rootId: root.id)

        #expect(outcome == .refused, "the old sequence has no editor to begin an operation in")
        let steps = rig.spyLog.items
        #expect(steps.contains("efJS"), "the editor-first call was made first: \(steps)")
        #expect(steps.contains("modeAwareFlush"), "then the old sequence ran: \(steps)")
        #expect(rig.events.items.contains { $0.contains("beginStructuralOp") }, "and asked the editor to begin the operation")
        #expect(!steps.contains("beginStructuralOp"), "which answered false, so the sequence stopped there: \(steps)")
        #expect(!steps.contains("createUndoPointSnapshot"), "no undo point was made for a refused press: \(steps)")
        #expect(!steps.contains("deleteSections"), "the delete itself (the old sequence's step 5) never ran: \(steps)")
        #expect(rig.unifiedUndo.undoStack.isEmpty, "a refused press records nothing")

        // Nothing was deleted: the document is the same, row for row, in the same order. The rows are compared by what they hold, NOT
        // by id: the old sequence's step 2 (`modeAwareFlush`) legitimately re-parses `editorState.content` into the block table,
        // which keeps the headings' ids and gives most other rows (the paragraphs here) fresh ones, and it runs BEFORE
        // `beginStructuralOp` is asked (EditorViewState+Zoom.swift, doc comment of `flushLiveContentToDatabase`). The first version
        // of this test compared the id sets and failed on those fresh ids although no row had been removed.
        let rowsAfter = try rig.blocks().sorted { $0.sortOrder < $1.sortOrder }
        let beforeContent = rowsBefore.map { "\($0.blockType): \($0.textContent)" }
        let afterContent = rowsAfter.map { "\($0.blockType): \($0.textContent)" }
        let idsBefore = Set(rowsBefore.map(\.id))
        let idsAfter = Set(rowsAfter.map(\.id))
        let idsOnlyBefore = idsBefore.subtracting(idsAfter).sorted()
        let idsOnlyAfter = idsAfter.subtracting(idsBefore).sorted()
        #expect(afterContent == beforeContent, "no row was deleted. ids only before: \(idsOnlyBefore); ids only after: \(idsOnlyAfter)")
        #expect(rowsAfter.contains { $0.textContent == "Second Section" }, "the section's heading is still there")
        #expect(rowsAfter.contains { $0.textContent == "The second section's body." }, "and so is its body")
        #expect(rig.editorState.efJobRegistry.outstandingCount == 0, "no job was queued")
        #expect(rig.editorState.pendingRemovalIds.isEmpty, "nothing was hidden from the sidebar")
        #expect(rig.alerts.isEmpty, "the alert comes from the caller (ContentView), not from the controller")
    }
}
