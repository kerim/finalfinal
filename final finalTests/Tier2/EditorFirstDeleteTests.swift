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
@MainActor
final class EditorFirstRig {
    let db: ProjectDatabase
    let pid: String
    let sync = BlockSyncService()
    let editorState = EditorViewState()
    let controller = StructuralUndoController()
    let unifiedUndo = UnifiedUndoService()
    let toasts = ToastCenter()
    let js = ScriptedJSEvaluator()
    /// The view the service is configured with (it keeps its own reference weakly).
    let view = WKWebView()
    /// Everything `deleteSectionEditorFirst` was asked, as the scripts the controller sent.
    private(set) var deleteScripts: [String] = []
    /// What the next `deleteSectionEditorFirst` call answers when no reply is registered for its root. Set by the test before it
    /// presses Delete Section.
    var deleteReply: Data?
    /// Replies by the root block id the call names (for tests that press Delete Section on several sections back to back).
    private var repliesByRoot: [String: Data] = [:]
    /// The order spy's log.
    let spyLog = GateOrderLog()
    /// Everything the editor was asked, in order: `js <script>` for every call the controller made through its eval seams, and
    /// `setContent preserve=<flag>` for every `setContentWithBlockIds` push. One log, so a test can assert the order across both.
    let events = GateOrderLog()
    /// Every `setContentWithBlockIds` push the controller made (the push itself is replaced by `testSetContentHook`).
    private(set) var pushes: [Push] = []
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
    private(set) var heldCountReads = 0
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

    struct Push {
        let markdown: String
        let blockIds: [String]
        let managedBlockIds: Set<String>
        let preserveUserBlocks: Bool
        /// `editorState.isResettingContent` at the moment the push ran: the flag that keeps the view from pushing `content` meanwhile.
        let isResettingContent: Bool
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
        pid = try TestFixtureFactory.getProjectId(from: db)
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
            annotationSyncService: AnnotationSyncService(), unifiedUndoService: unifiedUndo, findBarState: FindBarState())
        controller.testEvalBoolOverride = { [events, unowned self] js in
            events.note("js " + js)
            if js.contains("beginStructuralOp") { return self.beginStructuralOpAnswer }
            if js.contains("performStructuralSwap"), js.contains("'undo'"), let restored = self.editorTextAfterUndoSwap {
                self.editorText = restored
            }
            return StructuralUndoControllerTests.realisticEvalBoolDefault(js)
        }
        controller.testEvalVoidOverride = { [events] js in
            events.note("js " + js)
            return true
        }
        controller.testOrderingSpy = { [spyLog] step in spyLog.note(step) }
        controller.presentAlert = { [unowned self] alert in self.alerts.append(alert) }
        sync.testPushBlockIdsHook = { _ in }
        sync.testSetContentHook = { [unowned self] markdown, blockIds, managed, preserve in
            self.events.note("setContent preserve=\(preserve)")
            self.pushes.append(Push(
                markdown: markdown, blockIds: blockIds, managedBlockIds: managed, preserveUserBlocks: preserve,
                isResettingContent: self.editorState.isResettingContent))
            // A merge-guarded push keeps the editor's own blocks and takes the database's Notes and Bibliography; `editorText`, when a
            // test models the editor, becomes that merge. Otherwise the pushed text is the merge.
            if preserve {
                if self.modelsViewPushOfContent, !self.editorState.isResettingContent, self.editorText != nil {
                    self.editorText = self.editorState.content   // the view pushed `content` while the merge push was awaited
                }
                let merged = self.editorText.map { Self.mergingManagedRegions(editor: $0, database: markdown) } ?? markdown
                self.editorText = merged
                return merged
            }
            return nil
        }
        sync.testJSEvaluator = { [unowned self] script in
            if script.contains("deleteSectionEditorFirst") {
                self.deleteScripts.append(script)
                let registered = self.repliesByRoot.first { script.contains("\"\($0.key)\"") }?.value
                return (registered ?? self.deleteReply).flatMap { String(data: $0, encoding: .utf8) }
            }
            if script.contains("heldUndoPressCount") {
                self.heldCountReads += 1
                // A busy editor answers late (JavaScript is single-threaded: the call waits behind a long content push).
                if self.heldPressCountDelay > .zero { try? await Task.sleep(for: self.heldPressCountDelay) }
                return self.heldPressCountAnswer
            }
            if script.contains("getContent()") { return self.fetchAnswerProvider?() }
            return try await self.js.evaluate(script)
        }
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
        #expect(entry.isEditorFirstDelete)

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

    @Test("U14: a routine poll batch fetched BEFORE the click survives the delete")
    func testPollBatchFetchedBeforeClickSurvives() async throws {
        let rig = try EditorFirstRig(markdown: Self.threeSections)
        rig.controller.testEFBumpGenerationAtClick = Self.bumpGenerationAtClick
        let paragraph = try #require(try rig.blocks().first { $0.blockType == .paragraph && $0.textContent == "The first chapter's body." })
        let root = try rig.heading("Second Section")
        let subtreeIds = try #require(try rig.db.sectionBlockIds(rootId: root.id, projectId: rig.pid))

        // A routine cycle fetches a batch carrying the user's typing, then is held right after the fetch.
        let typed = BlockChanges(updates: [BlockUpdate(
            id: paragraph.id, textContent: "The first chapter's body. TYPED-U14", markdownFragment: "The first chapter's body. TYPED-U14",
            headingLevel: nil)])
        let typedJSON = String(data: try JSONEncoder().encode(typed), encoding: .utf8)
        rig.js.answer("hasBlockChanges", true)
        rig.js.answer("getBlockChanges", typedJSON)
        let parked = LifecycleEntryHarness.Gate()
        let entered = GateOrderLog()
        rig.sync.testAfterFetchHook = {
            entered.note("fetched")
            await parked.wait()
        }
        let poll = Task { @MainActor in await rig.sync.pollBlockChangesForTest() }
        let reached = await gateWaitUntil { entered.items == ["fetched"] }
        #expect(reached, "the routine cycle must have fetched its batch before the click")

        // The click: its own batch is empty (the poll took the typing), and it removes the section.
        try rig.setReply(.init(removedLeaderIds: [root.id]))
        let outcome = await rig.controller.performSectionDelete(rootId: root.id)
        #expect(outcome == .performed)
        let entry = try #require(rig.unifiedUndo.undoStack.last)

        parked.open()
        await poll.value
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
        try rig.setReply(.init(batch: typed, succeeded: false, reason: "rootNotFound", removedLeaderIds: []))

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
