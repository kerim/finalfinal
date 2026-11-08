//
//  EditorFirstRig+QuickUndo.swift
//  final finalTests
//
//  Tier 2 (t-94369a83 Phase 4b slice 2b): the quick path's side of the scripted editor of `EditorFirstRig` (EditorFirstDeleteTests.swift).
//  The stored properties stay in the class (an extension cannot hold them); everything that ANSWERS the editor's calls lives here:
//  `undoSectionDeleteEditorFirst`, `redoSectionDeleteEditorFirst`, `resumeSyncAfterQuickUndo`, `getContent()`, the typing queue and the
//  other scripts the class's evaluator closures hand over (`answerScript`).
//
//  The rig names NO production symbol the base commit lacks, so it compiles with the production change taken out (the must-fail
//  proof, QuickUndoMustFailTests.swift).
//
//  How `contentChanged` is produced: when the editor receives `resumeSyncAfterQuickUndo` (`noteResume`) and when the user types
//  (`typeIntoEditor`), `editorState.content` becomes the editor's live text at once, as the real editor's `contentChanged` message does
//  a few milliseconds later. `withholdContentUpdate` skips both (U-Q18, U-Q5).
//

import Foundation
import GRDB
import Testing
@testable import final_final

/// The JSON `undoSectionDeleteEditorFirst` answers (web-api-published.md section 1): the pending edits the call consumed, the verdict,
/// and the ids that came back. `reason` is present only on a refusal.
struct QuickUndoStubReply: Encodable {
    var batch = BlockChanges()
    var succeeded = true
    var reason: String?
    var restoredIds: [String] = []
    var restoredLeaderIds: [String] = []
    /// The leaders the undo took OUT (t-18b7fa48): empty for the undo of a delete, the copy's leaders for the undo of a duplicate.
    var removedLeaderIds: [String] = []
    /// t-d2061b27: present (as `true`) only when the page put the typing done during the wait back on top of the restored document.
    var typingReplayed: Bool?

    private enum CodingKeys: String, CodingKey {
        case batch
        case succeeded = "ok"
        case reason
        case restoredIds
        case restoredLeaderIds
        case removedLeaderIds
        case typingReplayed
    }
}

extension EditorFirstRig {

    /// What the editor did at one Delete Section click, kept so the quick path's answers can be derived (the database still holds
    /// the rows when the click's script is answered).
    struct DeleteClick {
        let opId: String
        let rootId: String
        /// Every block the section holds (database ids, document order) and the headings and section breaks among them.
        let subtreeIds: [String]
        let leaderIds: [String]
        /// The document as the database assembled it at the click: what the editor's pre-delete checkpoint holds.
        let preDeleteText: String
    }

    /// How the next `undoSectionDeleteEditorFirst` is answered.
    enum QuickUndoAnswer {
        /// The restore succeeds: the section's ids come back.
        case restore
        /// The editor refuses (`docChanged`, `notInFlight`, ...): nothing changes on the screen.
        case refuse(reason: String)
        /// The restore succeeds and returns this batch (the pending edits the call consumed).
        case restoreWithBatch(BlockChanges)
    }

    // MARK: - The scripted editor's evaluator

    /// Everything the class's `testJSEvaluator` is asked: the delete click, the quick undo and redo, the poll's two calls while the
    /// typing queue holds an edit, then the editor's other queries, then the scripted evaluator.
    func answerScript(_ wrapped: String) async throws -> Any? {
        // Phase 5 B3/B4: every editor-first route call arrives wrapped in the report cover (`BlockSyncService.coveredScript`). The
        // rig's page has no reports in flight to cover, so it answers the route itself; the wrapper is taken off first, and the
        // route's own reply goes back as it is (`unwrapCoveredReply` hands a reply that is not the wrapper through unchanged).
        let script = Self.innerRouteScript(wrapped)
        // The slow undo and redo (round 3c): `structuralSwapEditorFirst`, answered in EditorFirstRig+SlowUndo.swift.
        if script.contains("structuralSwapEditorFirst") { return answerSwapClick(script) }
        // The two calls that end the page's hold on the typing of a latched press (t-d2061b27; EditorFirstRig+TypingAcrossUndo.swift).
        if script.contains("releaseHeldTypingAndGetBatch") { return answerReleaseHeldTypingAndGetBatch(script) }
        if script.contains("releaseHeldTypingPushes") { return await answerReleaseHeldTypingPushes(script) }
        // Duplicate Section (t-18b7fa48): the click and the quick redo. (Neither name contains the other, nor the delete's.)
        if script.contains("redoSectionDuplicateEditorFirst") { return answerQuickRedoOfDuplicate(script) }
        if script.contains("duplicateSectionEditorFirst") { return answerDuplicateClick(script) }
        // The Version History restore (round 2d-i): the click and the quick redo. ("redoReplaceRangeEditorFirst" does not contain
        // "replaceRangeEditorFirst": the letter before "eplace" is a capital R.)
        if script.contains("redoReplaceRangeEditorFirst") { return answerQuickRedoOfReplace(script) }
        if script.contains("replaceRangeEditorFirst") { return answerReplaceClick(script) }
        if script.contains("deleteSectionEditorFirst") {
            deleteScripts.append(script)
            noteClick(script)
            let registered = repliesByRoot.first { script.contains("\"\($0.key)\"") }?.value
            return (registered ?? deleteReply).flatMap { String(data: $0, encoding: .utf8) }
        }
        if script.contains("undoSectionDeleteEditorFirst") { return await answerQuickUndo(script) }
        if script.contains("redoSectionDeleteEditorFirst") { return await answerQuickRedo(script) }
        return try await answerEditorQuery(script)
    }

    /// The editor's queries that need no scripting of the quick path: `flushAndAck`'s `flushReports` (the page posts the typing it
    /// holds as reports and answers its highest number), the held-press count, `getContent()`, everything else.
    private func answerEditorQuery(_ script: String) async throws -> Any? {
        if script.contains("flushReports") {
            flushReportsCalls += 1
            if wedgeNextFlushReports {
                wedgeNextFlushReports = false
                try? await Task.sleep(for: .seconds(60))   // never answers within any bound a test uses
                return nil
            }
            let through = postQueuedTyping()
            return "{\"session\":\"\(Self.reportSession)\",\"through\":\(through),\"held\":false,\"enabled\":true}"
        }
        if script.contains("heldUndoPressCount") {
            heldCountReads += 1
            // A busy editor answers late (JavaScript is single-threaded: the call waits behind a long content push).
            if heldPressCountDelay > .zero { try? await Task.sleep(for: heldPressCountDelay) }
            return heldPressCountAnswer
        }
        if script.contains("getContent()") {
            getContentCalls += 1
            let answer = fetchAnswerProvider?() ?? quickEditorText
            if let hold = getContentHold { await hold() }
            // The Rich Text save's live read (Phase 5 B3) asks for the content wrapped with the report hold.
            return script.contains("holdReportsForSave") ? heldReadAnswer(content: answer) : answer
        }
        return try await js.evaluate(script)
    }

    /// The route call inside a report-cover wrapper (`BlockSyncService.coveredScript`), or `script` itself when it is not wrapped.
    static func innerRouteScript(_ script: String) -> String {
        guard script.contains("beginReportCover"), let start = script.range(of: "try { v = ("),
              let end = script.range(of: "); } finally {", options: .backwards), start.upperBound <= end.lowerBound else { return script }
        return String(script[start.upperBound..<end.lowerBound])
    }

    /// The bridge's answer to `quickUndoLiveDiffersFromRestored` (S1-7): the override when a test set one, else whether the editor's live
    /// text is no longer the text the last quick restore put back.
    var liveDiffersFromRestored: Bool {
        if let liveDiffersOverride { return liveDiffersOverride }
        guard let live = quickEditorText, let restored = lastRestoredText else { return false }
        return live != restored
    }

    /// `controller.testEvalBoolOverride`: the old sequence's calls (`beginStructuralOp`, the slow undo's `performStructuralSwap`).
    func answerEvalBool(_ script: String) -> Bool {
        events.note("js " + script)
        if script.contains("quickUndoLiveDiffersFromRestored") { return liveDiffersFromRestored }
        if script.contains("beginStructuralOp") { return beginStructuralOpAnswer }
        if script.contains("performStructuralSwap"), script.contains("'undo'"), let restored = editorTextAfterUndoSwap {
            editorText = restored
        }
        return StructuralUndoControllerTests.realisticEvalBoolDefault(script)
    }

    /// `sync.testSetContentHook`: a merge-guarded push keeps the editor's own blocks and takes the database's Notes and Bibliography;
    /// `editorText`, when a test models the editor, becomes that merge. Otherwise the pushed text is the merge.
    func recordPush(
        markdown: String, blockIds: [String], managed: Set<String>, preserve: Bool
    ) -> String? {
        events.note("setContent preserve=\(preserve)")
        pushes.append(Push(
            markdown: markdown, blockIds: blockIds, managedBlockIds: managed, preserveUserBlocks: preserve,
            isResettingContent: editorState.isResettingContent, contentAtPush: editorState.content,
            detectPausedEdits: sync.testSetContentLastDetectPausedEdits))
        guard preserve else {
            if modelsWholePushOnEditor { applyWholePush(markdown) }
            return nil
        }
        if modelsViewPushOfContent, !editorState.isResettingContent, editorText != nil {
            editorText = editorState.content   // the view pushed `content` while the merge push was awaited
        }
        let merged = editorText.map { Self.mergingManagedRegions(editor: $0, database: markdown) } ?? markdown
        editorText = merged
        return merged
    }

    /// What the real editor does with a whole-document push (round 1g-A, review T1): its document becomes the pushed text. Keystrokes made
    /// while the push is in flight (`typedDuringNextWholePush`) survive as pending changes only when the push asked for
    /// `detectPausedEdits` (block-sync-plugin.ts `detectPausedEditsAndSnapshot`: it diffs the document against the snapshot taken when
    /// the push settled); without the option the replace has already discarded them.
    func applyWholePush(_ markdown: String) {
        editorText = markdown
        quickEditorText = markdown
        guard let typing = typedDuringNextWholePush else { return }
        typedDuringNextWholePush = nil
        if sync.testSetContentLastDetectPausedEdits { typeIntoEditor(typing.block, appending: typing.suffix) }
    }

    // MARK: - Waiting

    /// Waits (bounded) until no delete job, reinsert or settle is outstanding or unsettled: the database and the editor have caught
    /// up with everything the presses so far asked for. The quick undo replies BEFORE its reinsert has applied, so a test that reads
    /// the database after a quick Cmd-Z waits here first.
    @discardableResult
    func waitUntilSettled(iterations: Int = 4000) async -> Bool {
        await gateWaitUntil({ !self.editorState.efJobRegistry.hasUnsettledWork }, iterations: iterations)
    }

    // MARK: - Scripted answers of the quick path

    /// Every double-quoted string literal in `script`, in order (the operation id and the root id of a click are the first two).
    static func stringLiterals(in script: String) -> [String] {
        var result: [String] = []
        var current: String?
        var escaped = false
        for character in script {
            if var open = current {
                if escaped {
                    open.append(character)
                    escaped = false
                    current = open
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    result.append(open)
                    current = nil
                } else {
                    open.append(character)
                    current = open
                }
            } else if character == "\"" {
                current = ""
            }
        }
        return result
    }

    static func json(_ value: some Encodable) -> String? {
        (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Remembers what the delete click's editor would have held, before its reply is returned (the rows are still in the database).
    func noteClick(_ script: String) {
        let literals = Self.stringLiterals(in: script)
        guard literals.count >= 2 else { return }
        let opId = literals[0]
        let rootId = literals[1]
        if let copy = pendingDuplicateCopy(rootId: rootId), (try? db.sectionBlockIds(rootId: rootId, projectId: pid)) == nil {
            // Round 1g-A (review A1): the root is the copy of a duplicate whose job has not committed, so the database does not hold it.
            // The editor does: it holds the document with the copy, and the removal takes it back to the document before the duplicate.
            clicks[opId] = DeleteClick(
                opId: opId, rootId: rootId, subtreeIds: copy.copyIds, leaderIds: copy.copyLeaderIds,
                preDeleteText: editorText ?? quickEditorText ?? copy.preText)
            quickEditorText = copy.preText
            editorText = copy.preText
            if !withholdContentUpdate { editorState.content = copy.preText }   // `contentChanged` after the removal
            return
        }
        let subtree = (try? db.sectionBlockIds(rootId: rootId, projectId: pid)) ?? [rootId]
        let rowsById = Dictionary(((try? blocks()) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let leaders = subtree.filter { id in
            rowsById[id].map { ($0.blockType == .heading || $0.isPseudoSection) && !$0.isNotes } ?? false
        }
        clicks[opId] = DeleteClick(
            opId: opId, rootId: rootId, subtreeIds: subtree, leaderIds: leaders,
            preDeleteText: (try? assembledMarkdown()) ?? editorState.content)
    }

    /// `undoSectionDeleteEditorFirst("<opId>")`: the editor puts its pre-delete checkpoint back and answers the ids that came back.
    func answerQuickUndo(_ script: String) async -> Any? {
        events.note("js " + script)
        quickUndoScripts.append(script)
        if let hold = quickUndoReplyHold { await hold() }
        let opId = Self.stringLiterals(in: script).first ?? ""
        let click = clicks[opId]
        switch quickUndoAnswer {
        case .refuse(let reason):
            return Self.json(QuickUndoStubReply(succeeded: false, reason: reason))
        case .restore, .restoreWithBatch:
            var reply = QuickUndoStubReply(restoredIds: click?.subtreeIds ?? [], restoredLeaderIds: click?.leaderIds ?? [])
            // The undo of a DUPLICATE restores no ids (the pre-op document holds nothing the live one lacks) and takes the copy's
            // leaders out.
            let duplicate = duplicateClicks[opId]
            if let duplicate { reply = QuickUndoStubReply(removedLeaderIds: duplicate.copyLeaderIds + undoAlsoReportsRemoved) }
            // The undo of a RESTORE (round 2d-i) brings back the ids the restored document lacks and takes out the ones only it has.
            let replace = replaceClicks[opId]
            if let replace {
                let newIds = Set(replace.newIds)
                let previousIds = Set(replace.previousIds)
                reply = QuickUndoStubReply(
                    restoredIds: replace.previousIds.filter { !newIds.contains($0) },
                    restoredLeaderIds: replace.previousLeaderIds.filter { !newIds.contains($0) },
                    removedLeaderIds: replace.newLeaderIds.filter { !previousIds.contains($0) })
            }
            if case .restoreWithBatch(let batch) = quickUndoAnswer { reply.batch = batch }
            if quickUndoReplaysTyping {
                // The page put the wait typing back on top; the replay is its only carrier, so the batch is empty (t-d2061b27).
                quickUndoReplaysTyping = false
                reply.batch = BlockChanges()
                reply.typingReplayed = true
            }
            // The real swap puts the checkpoint's document into the editor; `editorTextAfterUndoSwap` is the same wish the slow path's
            // emulation honours.
            let restored = editorTextAfterUndoSwap ?? click?.preDeleteText ?? duplicate?.preText ?? replace?.preText
            if let restored {
                quickEditorText = restored
                editorText = restored
                lastRestoredText = restored
            }
            return Self.json(reply)
        }
    }

    /// `redoSectionDeleteEditorFirst("<opId>", "<rootId>", [...])`: a fresh removal of the current document, answered like the click.
    func answerQuickRedo(_ script: String) async -> Any? {
        events.note("js " + script)
        quickRedoScripts.append(script)
        if let hold = quickRedoReplyHold { await hold() }
        let literals = Self.stringLiterals(in: script)
        let opId = literals.first ?? ""
        let rootId = literals.dropFirst().first ?? ""
        let click = clicks[opId]
        let registered = repliesByRoot[rootId] ?? deleteReply
        let refused = registered.flatMap { String(data: $0, encoding: .utf8) }?.contains("\"ok\":false") == true
        if let click, !refused {
            // The document without the section, as the editor now shows it.
            let removed = Set(click.subtreeIds)
            let rows = ((try? blocks()) ?? []).filter { !removed.contains($0.id) }
                .sorted { ($0.sortOrder, $0.blockType == .heading ? 0 : 1) < ($1.sortOrder, $1.blockType == .heading ? 0 : 1) }
            let text = BlockParser.assembleMarkdownForEditor(from: rows)
            quickEditorText = text
            editorText = text
            if !withholdContentUpdate { editorState.content = text }   // `contentChanged` after the removal
        }
        if let registered, let text = String(data: registered, encoding: .utf8) { return addingTypedFlag(to: text) }
        return addingTypedFlag(to: Self.json(EditorFirstReply(removedLeaderIds: click?.leaderIds ?? [])))
    }

    /// `resumeSyncAfterQuickUndo()`: the editor queues what was typed while it was paused and, a few milliseconds later, tells Swift
    /// its live text (`contentChanged`). The rig makes that notification immediate: `content` becomes the editor's live text.
    /// `withholdContentUpdate` skips it, so `content` stays the post-delete text a reader of it must not trust.
    func noteResume(_ script: String) {
        resumeScripts.append(script)
        guard !withholdContentUpdate, let text = quickEditorText else { return }
        editorState.content = text
        runContentChangeHandlers()
    }

    /// What `ContentView`'s content-change handler does with the footnote service when `content` changes while the editor is idle
    /// (`checkAndUpdateFootnotes`). Off unless a test turns it on (`emulatesFootnoteContentChange`): only the footnote-checkpoint tests
    /// need it.
    func runContentChangeHandlers() {
        guard emulatesFootnoteContentChange, editorState.contentState == .idle else { return }
        let text = editorState.content
        footnotes.checkAndUpdateFootnotes(
            footnoteRefs: FootnoteSyncService.extractFootnoteRefs(from: text), projectId: pid, fullContent: text)
    }

    /// The editor's `contentChanged` push after a replacement of its document, through the 50 ms debounce: the footnote service's check of
    /// the new text runs AFTER the click's reply has been processed (and the job reserved), not inside the reply. `events` gets
    /// `content push` when it has run, so a test can wait for it. Only when a test turns `emulatesFootnoteContentChange` on; the slow
    /// undo's swap does the same inline (EditorFirstRig+SlowUndo.swift), the whole restore's click calls this (fix round F4).
    func emulateDebouncedContentPush() {
        guard emulatesFootnoteContentChange, !withholdContentUpdate else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            self?.runContentChangeHandlers()
            self?.events.note("content push")
        }
    }

    /// The page posts every edit it holds as one report each, in order, to the intake (as `report-outbox.ts` does when its debounce
    /// settles or Swift asks). Returns the highest report number posted so far.
    @discardableResult
    func postQueuedTyping() -> Int {
        while !typingQueue.isEmpty {
            reportsPosted += 1
            sync.reportApplier.receive(
                IncomingReport(number: reportsPosted, session: Self.reportSession, changes: typingQueue.removeFirst(), detectedAt: 0),
                via: .message)
        }
        return reportsPosted
    }

    /// Queues one edit the page will report next: `block`'s text gets `suffix` appended.
    func queueTyping(_ block: Block, appending suffix: String) {
        typingQueue.append(BlockChanges(updates: [BlockUpdate(
            id: block.id, textContent: block.textContent + suffix, markdownFragment: block.markdownFragment + suffix,
            headingLevel: nil)]))
    }

    /// The user types `suffix` at the end of `block`'s text: the editor's live text changes, `contentChanged` follows (unless
    /// withheld), and the edit waits in the page until it is reported (`startReport`, or `flushReports`).
    func typeIntoEditor(_ block: Block, appending suffix: String) {
        queueTyping(block, appending: suffix)
        guard let live = quickEditorText ?? editorText, let range = live.range(of: block.markdownFragment) else { return }
        let typed = live.replacingCharacters(in: range, with: block.markdownFragment + suffix)
        quickEditorText = typed
        editorText = typed
        if !withholdContentUpdate {
            editorState.content = typed
            runContentChangeHandlers()
        }
    }
}
