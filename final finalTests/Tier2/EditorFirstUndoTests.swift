//
//  EditorFirstUndoTests.swift
//  final finalTests
//
//  Tier 2 (t-94369a83 Phase 4b slice 2a, option (b): quick undo is slice 2b): Cmd-Z and Cmd-Shift-Z of an editor-first Delete
//  Section run today's snapshot-based undo with the snapshot id the delete's job recorded on the entry's slot.
//
//    - U9  `testBackToBackCommandsNeverRefused`: delete, delete, undo, redo, undo pressed back to back.
//    - U20 `testFallbackRedoReplacesAndUnpins`: delete, duplicate, Cmd-Z, Cmd-Z, Cmd-Shift-Z, Cmd-Z leave exactly the live ids pinned.
//    - A20 `UndoAfterInterleavedRebuildTests.testUndoReappliesDatabaseManagedRegions_book6`: after the slow undo's settle the
//      database's Notes and Bibliography are pushed into the editor.
//
//  Driven with `EditorFirstRig` (EditorFirstDeleteTests.swift): a real `BlockSyncService` and writer, the editor's JavaScript
//  scripted through `testJSEvaluator` / `testEvalBoolOverride` / `testEvalVoidOverride`, and the editor's content push replaced
//  by `BlockSyncService.testSetContentHook`.
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import GRDB
import Testing
@testable import final_final

@Suite("Editor-first undo and redo — Phase 4b slice 2a (Tier 2)", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct EditorFirstUndoTests {

    private static let fourSections = """
    # Chapter

    The chapter body.

    ## Section A

    The A body.

    ## Section B

    The B body.

    ## Section C

    The C body.
    """

    /// Sends one Cmd-Z or Cmd-Shift-Z for `opId` the way the editor's undo coordinator does.
    private func press(_ rig: EditorFirstRig, _ direction: StructuralUndoController.UndoDirection, _ opId: UUID) async {
        await rig.controller.handleStructuralRequest(opId: opId.uuidString, direction: direction)
    }

    /// The outcome words of every undo/redo reply the editor received, in order (`undo performed`, `redo fallback`, ...).
    private func replies(_ rig: EditorFirstRig) -> [String] {
        rig.events.items.compactMap { event -> String? in
            for (name, word) in [("receiveUndoOutcome", "undo"), ("receiveRedoOutcome", "redo")] where event.contains(name) {
                let outcome = ["performed", "fallback", "failed"].first { event.contains("'\($0)'") } ?? "?"
                return "\(word) \(outcome)"
            }
            return nil
        }
    }

    // MARK: - U9

    @Test("U9: delete, delete, undo, redo, undo pressed back to back: none is refused or failed, and they run in order")
    func testBackToBackCommandsNeverRefused() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        let sectionA = try rig.heading("Section A")
        let sectionB = try rig.heading("Section B")
        try rig.setReply(.init(removedLeaderIds: [sectionA.id]), forRoot: sectionA.id)
        try rig.setReply(.init(removedLeaderIds: [sectionB.id]), forRoot: sectionB.id)

        // Two Delete Section presses, the second while the first is still finishing: both run, neither is refused.
        let firstDelete = Task { @MainActor in await rig.controller.performSectionDelete(rootId: sectionA.id) }
        let secondDelete = Task { @MainActor in await rig.controller.performSectionDelete(rootId: sectionB.id) }
        let firstOutcome = await firstDelete.value
        let secondOutcome = await secondDelete.value
        #expect(firstOutcome == .performed)
        #expect(secondOutcome == .performed)
        let entries = rig.unifiedUndo.undoStack
        #expect(entries.count == 2)
        let entryB = try #require(entries.last)
        #expect(entries.first?.title == "Delete Section")
        for entry in entries { await rig.settle(entry.id) }
        try rig.syncEditorContentFromDatabase()
        let afterDeletes = Set(try rig.blocks().map(\.textContent))
        #expect(!afterDeletes.contains("Section A") && !afterDeletes.contains("Section B"), "both deletes must have reached the database")

        // Undo, redo, undo, all sent at once: they are held on the gate and run one after another.
        let undoOne = Task { @MainActor in await self.press(rig, .undo, entryB.id) }
        let redo = Task { @MainActor in await self.press(rig, .redo, entryB.id) }
        let undoTwo = Task { @MainActor in await self.press(rig, .undo, entryB.id) }
        await undoOne.value
        await redo.value
        await undoTwo.value

        #expect(replies(rig) == ["undo performed", "redo performed", "undo performed"], "got \(replies(rig))")
        // Slice 2b: a quick undo replies before its reinsert has applied; the database is read once everything has settled.
        _ = await rig.waitUntilSettled()
        let texts = Set(try rig.blocks().map(\.textContent))
        #expect(texts.contains("Section B"), "the last undo brings Section B back")
        #expect(!texts.contains("Section A"), "Section A, deleted first, stays deleted")
        #expect(rig.editorState.structuralGate.isIdle)
        #expect(!rig.controller.isPerforming)
    }

    // MARK: - Items 1, 6 and 12 of the fix round

    @Test("Item 1: the 'Undoing' notice stays up through the snapshot restore, the settle and the managed-region re-push, and is gone at the end")
    func testUndoingToastCoversTheRestoreAndTheSettle() async throws {
        let savedDelay = DelayedProgressToast.defaultDelay
        DelayedProgressToast.defaultDelay = .milliseconds(20)
        defer { DelayedProgressToast.defaultDelay = savedDelay }
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        rig.controller.testForceSlowDeleteUndo = true   // slice 2b: the "Undoing..." notice belongs to the slow path only (UX contract 4.2)
        rig.controller.testForceLegacyStructural = true   // t-18b7fa48 round 3c: pins the OLD slow body (its restore and settle run inside the press)
        let sectionA = try rig.heading("Section A")
        try rig.setReply(.init(removedLeaderIds: [sectionA.id]))
        let outcome = await rig.controller.performSectionDelete(rootId: sectionA.id)
        #expect(outcome == .performed)
        let entry = try #require(rig.unifiedUndo.undoStack.last)
        await rig.settle(entry.id)
        try rig.syncEditorContentFromDatabase()

        // The managed-region re-push is the LAST step of the settle, after the restore: when it runs, the notice must be showing.
        // (The old code dismissed the notice as soon as the snapshot id was found, before the restore even started.)
        let seen = GateOrderLog()
        rig.sync.testSetContentHook = { [unowned rig] markdown, _, _, preserve in
            if preserve {
                let shown = await gateWaitUntil { rig.toasts.current?.message == DelayedProgressToast.undoingMessage }
                seen.note(shown ? "undoing shown at the last step" : "undoing NOT shown at the last step")
            }
            return preserve ? markdown : nil
        }

        await press(rig, .undo, entry.id)

        #expect(seen.items == ["undoing shown at the last step"], "got \(seen.items)")
        #expect(rig.toasts.current == nil, "the notice is dismissed when the undo is over")
        #expect(replies(rig) == ["undo performed"])
    }

    @Test("Item 6: the merged text the re-push hands back becomes the content (like the rebuild handlers), so it is not pushed over again")
    func testUndoKeepsTheEditorsMergedTextAsContent() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        rig.controller.testForceSlowDeleteUndo = true   // slice 2b: this one pins the slow path's own re-push (its quick twin is below)
        rig.controller.testForceLegacyStructural = true   // t-18b7fa48 round 3c: pins the OLD slow body's re-push inside the press
        let sectionA = try rig.heading("Section A")
        try rig.setReply(.init(removedLeaderIds: [sectionA.id]))
        let outcome = await rig.controller.performSectionDelete(rootId: sectionA.id)
        #expect(outcome == .performed)
        let entry = try #require(rig.unifiedUndo.undoStack.last)
        await rig.settle(entry.id)
        try rig.syncEditorContentFromDatabase()
        // The editor's merge keeps what the user typed in a user block, so the text it returns DIFFERS from the database's.
        let typedMarker = "\n\nTYPED-AFTER-THE-UNDO"
        rig.sync.testSetContentHook = { markdown, _, _, preserve in preserve ? markdown + typedMarker : nil }

        await press(rig, .undo, entry.id)

        let databaseText = try rig.assembledMarkdown()
        #expect(rig.editorState.content.hasSuffix(typedMarker), "the merged text must become the content")
        #expect(rig.editorState.content != databaseText, "and it is not the database's text")
    }

    // MARK: - U20

    @Test("U20: delete, duplicate, Cmd-Z, Cmd-Z, Cmd-Shift-Z, Cmd-Z keep exactly the live snapshot ids pinned")
    func testFallbackRedoReplacesAndUnpins() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        // t-18b7fa48 round 1e-i: this test pins the legacy duplicate (its entry carries the undo and redo snapshot ids it reads
        // below); an editor-first duplicate entry keeps its snapshot on the slot like a delete's. The twin is U-S1-2a.
        rig.controller.testForceLegacyStructural = true
        let sectionA = try rig.heading("Section A")
        let sectionC = try rig.heading("Section C")
        try rig.setReply(.init(removedLeaderIds: [sectionA.id]))
        let snapshots = SnapshotService(database: rig.db, projectId: rig.pid)
        defer { for snapshot in (try? snapshots.fetchAllSnapshots()) ?? [] { SnapshotService.unpinUndoPointSnapshot(snapshot.id) } }

        // 1. Delete Section A (editor first); 2. Duplicate Section C (today's path).
        let deleteOutcome = await rig.controller.performSectionDelete(rootId: sectionA.id)
        #expect(deleteOutcome == .performed)
        let deleteEntry = try #require(rig.unifiedUndo.undoStack.last)
        await rig.settle(deleteEntry.id)
        try rig.syncEditorContentFromDatabase()
        let firstSnapshot = try #require(rig.controller.efSlots.slot(deleteEntry.id)?.snapshotId)
        let duplicateOutcome = await rig.controller.performSectionDuplicate(rootId: sectionC.id)
        #expect(duplicateOutcome == .performed)
        let duplicateEntry = try #require(rig.unifiedUndo.undoStack.last)
        #expect(duplicateEntry.id != deleteEntry.id)

        // 3. Cmd-Z undoes the duplicate; 4. Cmd-Z undoes the delete. (Slice 2b: the duplicate in between wrote the table outside the
        // queue, so the delete's undo is NOT eligible for the quick path (U-Q10) and this test still pins the slow path unchanged.)
        await press(rig, .undo, duplicateEntry.id)
        await press(rig, .undo, deleteEntry.id)
        let firstRedoSnapshot = try #require(rig.unifiedUndo.redoStack.last?.redoSnapshotId)
        #expect(rig.controller.efSlots.slot(deleteEntry.id)?.snapshotId == firstSnapshot)

        // 5. Cmd-Shift-Z redoes the delete: its slot takes the fresh undo snapshot and the old one is unpinned.
        await press(rig, .redo, deleteEntry.id)
        let refreshedSnapshot = try #require(rig.controller.efSlots.slot(deleteEntry.id)?.snapshotId)
        #expect(refreshedSnapshot != firstSnapshot, "the redo must write a fresh undo snapshot id onto the slot")

        // 6. Cmd-Z undoes the delete again.
        await press(rig, .undo, deleteEntry.id)

        let inThisProject = Set(try snapshots.fetchAllSnapshots().map(\.id))
        let pinned = SnapshotService.pinnedUndoPointSnapshotIdsForTesting.intersection(inThisProject)
        let undone = rig.unifiedUndo.redoStack
        let deleteOnRedo = try #require(undone.first { $0.id == deleteEntry.id })
        let duplicateOnRedo = try #require(undone.first { $0.id == duplicateEntry.id })
        var live: Set<String> = []
        live.insert(try #require(rig.controller.efSlots.slot(deleteEntry.id)?.snapshotId))
        live.insert(try #require(deleteOnRedo.redoSnapshotId))
        live.insert(try #require(duplicateOnRedo.undoSnapshotId))
        live.insert(try #require(duplicateOnRedo.redoSnapshotId))
        #expect(pinned == live, "pinned \(pinned.count) ids, live \(live.count): the pin set must hold exactly the live ids")
        #expect(!pinned.contains(firstSnapshot), "the delete's first snapshot was replaced and must be unpinned")
        #expect(!pinned.contains(firstRedoSnapshot), "the redo snapshot the first undo made was consumed by the redo and must be unpinned")
    }
}

@Suite("Undo after an interleaved rebuild — Phase 4b slice 2a (Tier 2)", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct UndoAfterInterleavedRebuildTests {

    @Test("A20: after the slow undo of an editor-first delete settles, the database's Notes and Bibliography are pushed into the editor")
    func testUndoReappliesDatabaseManagedRegions_book6() async throws {
        let rig = try EditorFirstRig(markdown: ComplexDocumentFixture.book6.editorMarkdown, configureSyncServices: false)
        rig.controller.testForceSlowDeleteUndo = true   // slice 2b: pins the slow path's order (quick twin: QuickUndoTamperTwinTests)
        rig.controller.testForceLegacyStructural = true   // t-18b7fa48 round 3c: pins the OLD slow body's order (settle, then the push)
        let chapter = try #require(try rig.chapterHeadings().first)
        let managedIds = Set(try rig.db.fetchManagedBlockIds(projectId: rig.pid))
        #expect(!managedIds.isEmpty, "the document must have flagged Notes and Bibliography rows")
        let bibliographyEntry = try #require(try rig.blocks().first { $0.isBibliography && $0.blockType != .heading })
        try rig.setReply(.init(removedLeaderIds: [chapter.id]))

        // The click's ticket is reserved, but the delete job waits behind an earlier editor sequence, so a rebuild can be applied
        // in between: the database's bibliography is rewritten here, before the job writes its Version History copy.
        let blocker = try rig.holdQueue()
        let deleteOutcome = await rig.controller.performSectionDelete(rootId: chapter.id)
        #expect(deleteOutcome == .performed)
        try rig.rewriteText(ofBlock: bibliographyEntry.id, to: bibliographyEntry.textContent + " REBUILT-A20")
        rig.release(blocker)
        let entry = try #require(rig.unifiedUndo.undoStack.last)
        await rig.settle(entry.id)
        try rig.syncEditorContentFromDatabase()

        await rig.controller.handleStructuralRequest(opId: entry.id.uuidString, direction: .undo)

        let regionPushes = rig.pushes.filter { $0.preserveUserBlocks }
        #expect(regionPushes.count == 1, "exactly one merge-guarded push of the database's managed regions: \(regionPushes.count)")
        let push = try #require(regionPushes.first)
        #expect(push.managedBlockIds == Set(try rig.db.fetchManagedBlockIds(projectId: rig.pid)),
                "the managed ids come from the database")
        #expect(push.markdown.contains("REBUILT-A20"), "expected editor bibliography to equal database bibliography")
        let finish = try #require(rig.events.items.lastIndex { $0.contains("finishStructuralSwapSettle") })
        let pushed = try #require(rig.events.items.lastIndex { $0 == "setContent preserve=true" })
        #expect(finish < pushed, "the managed-region push is the LAST step of the settle, after finishStructuralSwapSettle")
        #expect(rig.scripts(containing: "receiveUndoOutcome").first?.contains("'performed'") == true)

        // The plan's cached-citekeys assertion (A20), as far as a unit test can reach it. `BibliographySyncService` sets its cache
        // only when a real, Zotero-backed rebuild writes (`ZoteroService` is not connected in a unit test, so `resyncNow` returns
        // before it commits anything), so the cache itself cannot be read here, and this test does not pretend to. What the code
        // GUARANTEES, and this asserts: the resync that follows the settle is fed `editorState.content`, which the settle set from
        // the DATABASE's assembled document (the editor's text only replaces it when the merge differs, item 6), so the citekeys
        // it receives are the database's, not the editor's.
        let databaseKeys = BibliographySyncService.extractCitekeys(from: try rig.assembledMarkdown())
        #expect(!databaseKeys.isEmpty, "book6 cites a lot")
        #expect(BibliographySyncService.extractCitekeys(from: rig.editorState.content) == databaseKeys,
                "the citekeys the resync is fed are the restored database document's")
    }
}
