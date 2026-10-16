//
//  QuickUndoTamperTwinTests.swift
//  final finalTests
//
//  This file: the quick twins of the existing tests whose subject is the slow path (the "Undoing..." notice, the merged text, A20, the
//  rebuild wait, U15).
//  Tier 2 (t-94369a83 Phase 4b slice 2b; plan-v1 F2, plan-v2-addendum 6.2, plan-v3-addendum A1/D1/D2/D7, plan-v4-addendum 5): guards of
//  the quick undo and quick redo of an editor-first Delete Section, driven with `EditorFirstRig` (EditorFirstDeleteTests.swift). The
//  quick undo replies BEFORE its reinsert has applied, so every test that reads the database waits with
//  `EditorFirstRig.waitUntilSettled()` first. Every wait is bounded. Shared helpers: QuickUndoFixtures.swift.
//

import Foundation
import GRDB
import Testing
@testable import final_final

@Suite("Quick undo: twins of the slow-path tests that were forced slow (Phase 4b slice 2b, Tier 2)", .serialized, .timeLimit(.minutes(6)))
@MainActor
struct QuickUndoTamperTwinTests: QuickUndoFixtures {

    // MARK: - Twins of the tamper rows

    @Test("Twin of the toast test: the quick undo shows no 'Undoing…' notice, even past the notice's delay")
    func testQuickUndoShowsNoToast() async throws {
        let savedDelay = DelayedProgressToast.defaultDelay
        DelayedProgressToast.defaultDelay = .milliseconds(20)
        defer { DelayedProgressToast.defaultDelay = savedDelay }
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        let sectionA = try rig.heading("Section A")
        try rig.setReply(.init(removedLeaderIds: [sectionA.id]))
        _ = await rig.controller.performSectionDelete(rootId: sectionA.id)
        let entry = try #require(rig.unifiedUndo.undoStack.last)
        await rig.settle(entry.id)
        try rig.syncEditorContentFromDatabase()
        let seen = GateOrderLog()
        rig.controller.testQuickUndoResumeHold = {
            try? await Task.sleep(for: .milliseconds(120))
            seen.note(rig.toasts.current?.message == DelayedProgressToast.undoingMessage ? "undoing shown" : "no notice")
        }

        #expect(await rig.pressAndSettle(entry))

        #expect(seen.items == ["no notice"], "the quick undo is instant and shows nothing: \(seen.items)")
        #expect(rig.toasts.current?.message != DelayedProgressToast.undoingMessage)
        #expect(rig.replyWords() == ["undo performed"])
    }

    @Test("Twin of the merged-text test: the merged text the settle's re-push hands back becomes the content (not the database's text)")
    func testQuickUndoKeepsTheEditorsMergedTextAsContent() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        let sectionA = try rig.heading("Section A")
        try rig.setReply(.init(removedLeaderIds: [sectionA.id]))
        _ = await rig.controller.performSectionDelete(rootId: sectionA.id)
        let entry = try #require(rig.unifiedUndo.undoStack.last)
        await rig.settle(entry.id)
        try rig.syncEditorContentFromDatabase()
        let typedMarker = "\n\nTYPED-AFTER-THE-UNDO"
        rig.sync.testSetContentHook = { markdown, _, _, preserve in preserve ? markdown + typedMarker : nil }

        #expect(await rig.pressAndSettle(entry))

        #expect(rig.editorState.content.hasSuffix(typedMarker), "the merged text must become the content")
        let databaseText = try rig.assembledMarkdown()
        let contentIsDatabaseText = rig.editorState.content == databaseText
        #expect(!contentIsDatabaseText, "and it is not the database's text")
    }

    // Twin of A20: after the quick undo settles, the database's Notes and Bibliography are pushed into the editor, exactly one
    // merge-guarded push, after the editor was resumed
    @Test("Twin of A20: after the quick undo settles")
    func testQuickUndoReappliesDatabaseManagedRegions_book6() async throws {
        let rig = try makeBookRig()
        let chapter = try #require(try rig.chapterHeadings().first)
        let bibliographyEntry = try #require(try rig.blocks().first { $0.isBibliography && $0.blockType != .heading })
        try rig.setReply(.init(removedLeaderIds: [chapter.id]))
        let blocker = try rig.holdQueue()
        let outcome = await rig.controller.performSectionDelete(rootId: chapter.id)
        #expect(outcome == .performed)
        // A rebuild is applied between the click and the job: the database's bibliography is rewritten here.
        try rig.rewriteText(ofBlock: bibliographyEntry.id, to: bibliographyEntry.textContent + " REBUILT-A20")
        rig.release(blocker)
        let entry = try #require(rig.unifiedUndo.undoStack.last)
        await rig.settle(entry.id)
        try rig.syncEditorContentFromDatabase()

        #expect(await rig.pressAndSettle(entry))

        let regionPushes = rig.pushes.filter(\.preserveUserBlocks)
        #expect(regionPushes.count == 1, "exactly one merge-guarded push of the database's managed regions: \(regionPushes.count)")
        let push = try #require(regionPushes.first)
        let fetchedManagedIds = try rig.db.fetchManagedBlockIds(projectId: rig.pid)
        let databaseManagedIds = Set(fetchedManagedIds)
        let managedIdsMatch = push.managedBlockIds == databaseManagedIds
        #expect(managedIdsMatch, "the managed ids come from the database (push \(push.managedBlockIds.count), database \(databaseManagedIds.count))")
        #expect(push.isResettingContent, "the view is held off while the push runs: no whole-document push of the database text over the editor")
        #expect(
            push.contentAtPush != push.markdown && !push.contentAtPush.contains("REBUILT-A20"),
            "expected 0 whole-document pushes of the database text over the editor: `content` held the database's text at the push")
        #expect(push.markdown.contains("REBUILT-A20"), "expected editor bibliography to equal database bibliography")
        let resumed = try #require(rig.events.items.lastIndex { $0.contains("resumeSyncAfterQuickUndo") })
        let pushed = try #require(rig.events.items.lastIndex { $0 == "setContent preserve=true" })
        #expect(resumed < pushed, "the managed-region push comes after the editor was resumed")
    }

    // Twin of the rebuild-wait test: after Cmd-Z at once, with the delete's rebuild still in flight, the restore is not held by it, and
    // once everything settled the Notes match the references
    @Test("Twin of the rebuild-wait test: after Cmd-Z at once")
    func testQuickUndoAtOnceAfterDeleteSettlesNotesAfterTheRebuild_article() async throws {
        let rig = try makeArticleRig()
        let before = try rig.assembledMarkdown()
        let deleted = try await delete(rig, Self.villageRegisters, settle: false)
        let mayLand = LifecycleEntryHarness.Gate()
        defer { mayLand.open() }
        rig.controller.testEFSettleHold = { [weak rig] in
            guard let rig else { return }
            _ = try? rig.syncEditorContentFromDatabase()
            self.startStampedRebuild(rig, mayLand: mayLand)
        }
        let started = await gateWaitUntil({ rig.events.items.contains("rebuild read") }, iterations: 4000)
        #expect(started, "the delete's follow-up work must have started its rebuild")

        let undo = rig.startPress(deleted.entry)
        let restoredWhileRebuildRuns = await rig.awaitRuns([undo])
        #expect(restoredWhileRebuildRuns, "expected the quick restore while a rebuild is still running (the restore waited for the rebuild)")
        mayLand.open()
        _ = await rig.waitUntilSettled()

        #expect(try rig.documentDiff(before) == nil, "no definition is lost: the document is as it was")
        let labels = EditorFirstFootnoteLifecycleTests.footnoteLabels(in: try rig.assembledMarkdown())
        #expect(labels.references.count == 9 && labels.definitions.count == 9, "\(labels)")
        #expect(rig.scripts(containing: "performStructuralSwap").isEmpty)
    }

    // Twin of U15 (G-T1): a quit right after the quick undo, with the delete's job still queued, releases the gate; the saved document
    // holds the restored section and the text typed after the undo; and nothing is left unsettled (the reinsert's marker ends with it).
    @Test("Twin of U15: a quit right after the quick undo, with the job pending, saves the section and the typing")
    func testQuitRightAfterQuickUndoWithTheJobPendingReleasesTheGate() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        rig.js.answer("flushPendingBlockChanges", true)
        rig.js.answer("hasBlockChanges", false)
        let sectionA = try rig.heading("Section A")
        let typedParagraph = try #require(try rig.blocks().first { $0.textContent == "The B body." })
        try rig.setReply(.init(removedLeaderIds: [sectionA.id]))
        let blocker = try rig.holdQueue()
        defer { rig.release(blocker) }
        _ = await rig.controller.performSectionDelete(rootId: sectionA.id)
        let entry = try #require(rig.unifiedUndo.undoStack.last)

        let undo = rig.startPress(entry)
        #expect(await rig.awaitRuns([undo]), "the quick undo does not wait for the pending job")
        // The editor holds the restored section and the typing (`getContent()` answers its live text).
        rig.typeIntoEditor(typedParagraph, appending: " TYPED-QUIT")
        // The quit starts while the delete's job and the reinsert wait behind the held ticket; the ticket goes a moment later (the
        // editor that was slow answers), so the quit has time to wait for them and then to save.
        let quit = Task { @MainActor in await rig.runLifecycle(.quit, bounds: LifecycleBounds.production.scaled(0.5)) }
        try await Task.sleep(for: .milliseconds(300))
        rig.release(blocker)
        let result = await quit.value

        #expect(rig.replyWords() == ["undo performed"], "got \(rig.replyWords())")
        #expect(rig.editorState.structuralGate.isIdle, "the gate was released")
        #expect(!rig.controller.isPerforming)
        #expect(!result.opStillRunning, "the quit found the reinsert and its settle finished: its marker ends with it")
        let settled = await rig.waitUntilSettled(iterations: 800)
        #expect(settled, "nothing is left unsettled after the quit (outcome \(result.outcome))")
        let rows = try rig.blocks()
        #expect(rows.contains { $0.textContent == "Section A" }, "the saved rows contain the restored section")
        #expect(rows.contains { $0.textContent.contains("TYPED-QUIT") }, "and the text typed after the undo")
    }
}
